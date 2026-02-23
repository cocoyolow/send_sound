import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

// ── UUIDs ──────────────────────────────────────────────────────────────────
const String kServiceUuid = "12345678-1234-5678-1234-56789abcdef0";
const String kWriteUuid   = "12345678-1234-5678-1234-56789abcdef1";
const String kNotifyUuid  = "12345678-1234-5678-1234-56789abcdef2";

// ── Protocol ───────────────────────────────────────────────────────────────
// First packet: 8-byte LE int64 = total file size.
const int kHeaderSize = 8;
// End sentinel: 0xFF 0x00 is forbidden in MPEG streams (anti-emulation),
// making this 8-byte sequence impossible in any valid MP3/WAV/AAC file.
const List<int> kEndSentinel = [0xFF, 0x00, 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE];

bool _isSentinel(Uint8List c) {
  if (c.length != kEndSentinel.length) return false;
  for (int i = 0; i < kEndSentinel.length; i++) {
    if (c[i] != kEndSentinel[i]) return false;
  }
  return true;
}

// ── BLE Streaming Audio Source ─────────────────────────────────────────────
// Feeds BLE chunks directly into ExoPlayer as they arrive over the air.
// We buffer the data so ExoPlayer can read from the beginning (including MP3 headers)
// even if chunks arrive before it connects to the local proxy HTTP server.
class _BleStreamSource extends StreamAudioSource {
  final int totalSize;
  final List<int> _buffer = [];
  bool _finished = false;
  // A controller that fires whenever new data is added to the buffer.
  final StreamController<void> _newDataEvent = StreamController<void>.broadcast();

  final String contentType;

  _BleStreamSource(this.totalSize, {this.contentType = 'audio/mpeg'});

  /// Push a BLE chunk into the player pipeline.
  void addChunk(Uint8List chunk) {
    if (_finished) return;
    _buffer.addAll(chunk);
    _newDataEvent.add(null);
  }

  /// Signal end-of-stream.
  void finish() {
    if (_finished) return;
    _finished = true;
    _newDataEvent.add(null);
    _newDataEvent.close();
  }

  int get bytesReceived => _buffer.length;

  /// A generator that yields bytes from the buffer starting at [startOffset].
  /// It awaits new data if it reaches the end of the buffer while the stream
  /// is still active. This satisfies ExoPlayer's HTTP proxy requests.
  Stream<List<int>> _streamFrom(int startOffset, int? endOffset) async* {
    int position = startOffset;
    while (position < (endOffset ?? totalSize)) {
      if (position < _buffer.length) {
        // Yield available data up to endOffset
        final chunkLength = _buffer.length - position;
        final sizeToYield = endOffset != null 
            ? ((position + chunkLength > endOffset) ? endOffset - position : chunkLength)
            : chunkLength;
            
        final chunk = _buffer.sublist(position, position + sizeToYield);
        position += chunk.length;
        yield chunk;
      } else if (_finished) {
        // Reached end of finished stream
        break;
      } else {
        // Wait for more data to arrive
        await _newDataEvent.stream.first;
      }
    }
  }

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final startOffset = start ?? 0;
    
    return StreamAudioResponse(
      sourceLength: totalSize,
      contentLength: end != null ? end - startOffset : totalSize - startOffset,
      offset: startOffset,
      stream: _streamFrom(startOffset, end),
      contentType: contentType,
    );
  }
}

// ── App ────────────────────────────────────────────────────────────────────
void main() => runApp(const SoundReceiverApp());

class SoundReceiverApp extends StatelessWidget {
  const SoundReceiverApp({super.key});
  @override
  Widget build(BuildContext context) => const MaterialApp(
        title: 'SoundReceiver',
        home: SoundReceiverPage(),
        debugShowCheckedModeBanner: false,
      );
}

class SoundReceiverPage extends StatefulWidget {
  const SoundReceiverPage({super.key});
  @override
  State<SoundReceiverPage> createState() => _SoundReceiverPageState();
}

class _SoundReceiverPageState extends State<SoundReceiverPage> {
  final _player = AudioPlayer();
  String _status = 'Initialisation...';
  bool _advertising = false;

  // Transfer state
  int _expectedSize = -1;        // set from header packet; -1 = not received
  _BleStreamSource? _source;     // current streaming source fed by BLE chunks
  String? _currentDevice;        // device we're streaming from

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await [
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
    ].request();

    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    await BlePeripheral.initialize();

    BlePeripheral.setAdvertisingStatusUpdateCallback(
      (bool advertising, String? error) => setState(() {
        _advertising = advertising;
        _status = error != null
            ? 'Erreur advertising: $error'
            : advertising
                ? 'BLE actif — en attente de connexion...'
                : 'Advertising arrêté';
      }),
    );

    BlePeripheral.setWriteRequestCallback(
      (String deviceId, String charId, int offset, Uint8List? value) {
        if (value != null) _onChunk(deviceId, value);
        return null; // GATT_SUCCESS
      },
    );

    BlePeripheral.setConnectionStateChangeCallback(
      (String deviceId, bool connected) {
        setState(() => _status = connected
            ? 'Connecté à $deviceId'
            : 'Déconnecté — en attente...');
        if (!connected) _abortStream();
      },
    );

    await _addService();
    await _startAdvertising();
  }

  // ── Transfer state management ─────────────────────────────────────────────

  void _abortStream() {
    _source?.finish();
    _source = null;
    _expectedSize = -1;
    _currentDevice = null;
    _player.stop();
  }

  Future<void> _startStream(String deviceId, int totalBytes) async {
    // Tear down any previous stream cleanly
    await _player.stop();
    _source?.finish();

    _expectedSize  = totalBytes;
    _currentDevice = deviceId;
    _source        = _BleStreamSource(totalBytes, contentType: 'audio/mpeg');

    try {
      // Hand ExoPlayer our live BLE stream.
      // It will buffer a few KB then start playing automatically.
      await _player.setAudioSource(_source!);
      await _player.play();
      setState(() => _status = 'Lecture en cours... (0 / $totalBytes o)');
    } catch (e) {
      debugPrint('[stream] setAudioSource error: $e');
      setState(() => _status = 'Erreur démarrage: $e');
      _abortStream();
    }
  }

  // ── BLE packet handler ────────────────────────────────────────────────────

  void _onChunk(String deviceId, Uint8List chunk) async {
    if (chunk.isEmpty) return;

    // ── 1. End sentinel ──────────────────────────────────────────────────────
    if (_isSentinel(chunk)) {
      final received = _source?.bytesReceived ?? 0;
      debugPrint('[ble] Sentinel — reçu=$received attendu=$_expectedSize');

      if (_expectedSize != -1 && received != _expectedSize) {
        // Packet loss: stream is corrupted — stop playback
        debugPrint('[ble] ERREUR: transfert incomplet ($received/$_expectedSize o)');
        setState(() => _status = 'Incomplet ($received/$_expectedSize o)');
        await _notify(deviceId, 'error:$received/$_expectedSize');
        _abortStream();
        return;
      }

      // Save for debug
      try {
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}/debug.mp3');
        await file.writeAsBytes(_source!._buffer, flush: true);
        debugPrint('[ble] Saved debug file: ${file.path}');
      } catch (e) {
        debugPrint('[ble] Error saving debug: $e');
      }

      // Close the stream — ExoPlayer plays out the remaining buffer
      _source?.finish();
      setState(() => _status = 'Lecture ✓ ($received o)');
      await _notify(deviceId, 'ok');

      // Reset for next transfer (keep player alive to finish playing)
      _expectedSize  = -1;
      _currentDevice = null;
      _source        = null;
      return;
    }

    // ── 2. Header: 8-byte LE int64 total file size ──────────────────────────
    //    Sent by the CLI as the very first write.
    //    On receipt we immediately create the audio source and start playback.
    if (_expectedSize == -1 && chunk.length == kHeaderSize) {
      final totalBytes = ByteData.sublistView(chunk).getInt64(0, Endian.little);
      debugPrint('[ble] Header: $totalBytes octets attendus');
      // Start playback pipeline before first audio byte arrives
      await _startStream(deviceId, totalBytes);
      return;
    }

    // ── 3. Audio data chunk → push straight into ExoPlayer ──────────────────
    if (_source == null) {
      // Chunk arrived before header (out of order) — ignore
      debugPrint('[ble] Chunk avant header — ignoré (${chunk.length} o)');
      return;
    }

    _source!.addChunk(chunk);

    // Throttled UI progress (every ~8 KB)
    final received = _source!.bytesReceived;
    if (_expectedSize > 0 && received % 8192 < chunk.length) {
      setState(() => _status = 'Lecture... ($received / $_expectedSize o)');
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Future<void> _notify(String deviceId, String msg) async {
    try {
      await BlePeripheral.updateCharacteristic(
        characteristicId: kNotifyUuid,
        value: Uint8List.fromList(utf8.encode(msg)),
        deviceId: deviceId,
      );
    } catch (e) {
      debugPrint('[notify] $e');
    }
  }

  Future<void> _addService() async {
    await BlePeripheral.addService(BleService(
      uuid: kServiceUuid,
      primary: true,
      characteristics: [
        BleCharacteristic(
          uuid: kWriteUuid,
          properties: [
            CharacteristicProperties.write.index,
            CharacteristicProperties.writeWithoutResponse.index,
          ],
          value: null,
          permissions: [AttributePermissions.writeable.index],
        ),
        BleCharacteristic(
          uuid: kNotifyUuid,
          properties: [
            CharacteristicProperties.read.index,
            CharacteristicProperties.notify.index,
          ],
          value: null,
          permissions: [AttributePermissions.readable.index],
        ),
      ],
    ));
  }

  Future<void> _startAdvertising() async {
    await BlePeripheral.startAdvertising(services: [kServiceUuid]);
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.bluetooth,
                  color: _advertising ? Colors.blueAccent : Colors.grey,
                  size: 64),
              const SizedBox(height: 24),
              const Text('SoundReceiver',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              Text(_status,
                  style: const TextStyle(color: Colors.grey, fontSize: 14),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      );

  @override
  void dispose() {
    _player.dispose();
    _source?.finish();
    BlePeripheral.stopAdvertising();
    super.dispose();
  }
}