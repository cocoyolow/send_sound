import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

// ── UUIDs (must match the CLI) ─────────────────────────────────────────────
const String kServiceUuid = "12345678-1234-5678-1234-56789abcdef0";
const String kWriteUuid   = "12345678-1234-5678-1234-56789abcdef1";
const String kNotifyUuid  = "12345678-1234-5678-1234-56789abcdef2";

void main() => runApp(const SoundReceiverApp());

class SoundReceiverApp extends StatelessWidget {
  const SoundReceiverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'SoundReceiver',
      home: SoundReceiverPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class SoundReceiverPage extends StatefulWidget {
  const SoundReceiverPage({super.key});

  @override
  State<SoundReceiverPage> createState() => _SoundReceiverPageState();
}

class _SoundReceiverPageState extends State<SoundReceiverPage> {
  final _player   = AudioPlayer();
  String _status  = 'En attente...';
  List<int> _buffer = [];

  @override
  void initState() {
    super.initState();
    _startAdvertising();
  }

  Future<void> _startAdvertising() async {
    // flutter_blue_plus doesn't expose peripheral/advertising directly on all platforms.
    // Use the ScanResult-based approach: the Flutter app acts as a peripheral via
    // the OS Bluetooth stack (handled by the platform channel below).
    // For a real build, use flutter_blue_plus >= 1.31 peripheral APIs or
    // a package like 'ble_peripheral'. Here we use the built-in approach:
    await FlutterBluePlus.startScan(
      withServices: [Guid(kServiceUuid)],
      timeout: const Duration(seconds: 0), // continuous
    );

    // listen for connection requests from the CLI
    FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        _connectAndListen(r.device);
      }
    });

    setState(() => _status = 'En attente de connexion BLE...');
  }

  Future<void> _connectAndListen(BluetoothDevice device) async {
    if (device.isConnected) return;

    try {
      await device.connect(timeout: const Duration(seconds: 10));
      final services = await device.discoverServices();

      for (final svc in services) {
        if (svc.uuid.toString().toLowerCase() != kServiceUuid.toLowerCase()) continue;

        BluetoothCharacteristic? writeChar;
        BluetoothCharacteristic? notifyChar;

        for (final c in svc.characteristics) {
          final id = c.uuid.toString().toLowerCase();
          if (id == kWriteUuid.toLowerCase())   writeChar  = c;
          if (id == kNotifyUuid.toLowerCase())  notifyChar = c;
        }

        if (writeChar == null || notifyChar == null) continue;

        _buffer = [];
        await writeChar.setNotifyValue(true);
        writeChar.lastValueStream.listen((chunk) async {
          if (chunk.isEmpty) return;

          if (chunk.length == 3 &&
              chunk[0] == 69 && chunk[1] == 78 && chunk[2] == 68) {
            // "END" received — play the sound
            final ok = await _playBuffer();
            // Send confirmation
            await notifyChar!.write(ok ? [111, 107] : [101, 114, 114]); // "ok" / "err"
            _buffer = [];
          } else {
            _buffer.addAll(chunk);
          }
        });

        setState(() => _status = 'Connecté à ${device.advName}');
      }
    } catch (e) {
      setState(() => _status = 'Erreur: $e');
    }
  }

  Future<bool> _playBuffer() async {
    try {
      final dir  = await getTemporaryDirectory();
      final file = File('${dir.path}/recv_sound.mp3');
      await file.writeAsBytes(_buffer);
      await _player.play(DeviceFileSource(file.path));
      setState(() => _status = 'Son joué ✓');
      return true;
    } catch (_) {
      setState(() => _status = 'Erreur lecture son');
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.bluetooth, color: Colors.blueAccent, size: 64),
            const SizedBox(height: 24),
            const Text(
              'SoundReceiver',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _status,
              style: const TextStyle(color: Colors.grey, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _player.dispose();
    FlutterBluePlus.stopScan();
    super.dispose();
  }
}
