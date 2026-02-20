import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:ble_peripheral/ble_peripheral.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

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
  final _player  = AudioPlayer();
  String _status = 'Initialisation...';
  List<int> _buffer = [];
  bool _advertising = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // Request Bluetooth permissions (Android 12+)
    await [
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
    ].request();

    // Initialize BLE Peripheral
    await BlePeripheral.initialize();

    // Set up callbacks
    BlePeripheral.setAdvertisingStatusUpdateCallback(
      (bool advertising, String? error) {
        setState(() {
          _advertising = advertising;
          if (error != null) {
            _status = 'Erreur advertising: $error';
          } else {
            _status = advertising
                ? 'BLE actif — en attente de connexion...'
                : 'Advertising arrêté';
          }
        });
      },
    );

    BlePeripheral.setWriteRequestCallback(
      (String deviceId, String characteristicId, int offset, Uint8List? value) {
        if (value != null) {
          _onChunkReceived(deviceId, value);
        }
        return null; // GATT_SUCCESS (null = accept the write)
      },
    );

    BlePeripheral.setConnectionStateChangeCallback(
      (String deviceId, bool connected) {
        setState(() {
          _status = connected
              ? 'Connecté à $deviceId'
              : 'Déconnecté — en attente...';
        });
        if (!connected) {
          _buffer = [];
        }
      },
    );

    // Add the GATT service with write + notify characteristics
    await _addGattService();

    // Start advertising
    await _startAdvertising();
  }

  Future<void> _addGattService() async {
    await BlePeripheral.addService(
      BleService(
        uuid: kServiceUuid,
        primary: true,
        characteristics: [
          // Characteristic for receiving audio chunks (writable by Central)
          BleCharacteristic(
            uuid: kWriteUuid,
            properties: [
              CharacteristicProperties.write.index,
              CharacteristicProperties.writeWithoutResponse.index,
            ],
            value: null,
            permissions: [
              AttributePermissions.writeable.index,
            ],
          ),
          // Characteristic for sending confirmations (notify to Central)
          BleCharacteristic(
            uuid: kNotifyUuid,
            properties: [
              CharacteristicProperties.read.index,
              CharacteristicProperties.notify.index,
            ],
            value: null,
            permissions: [
              AttributePermissions.readable.index,
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _startAdvertising() async {
    // Note: on Android, the advertisement packet is limited to 31 bytes.
    // A 128-bit UUID takes 18 bytes. Adding localName would overflow,
    // causing Android to silently drop the service UUID.
    await BlePeripheral.startAdvertising(
      services: [kServiceUuid],
    );
  }

  void _onChunkReceived(String deviceId, Uint8List chunk) async {
    if (chunk.isEmpty) return;

    // Check for "END" sentinel (3 bytes: E=69, N=78, D=68)
    if (chunk.length == 3 &&
        chunk[0] == 69 && chunk[1] == 78 && chunk[2] == 68) {
      // End of file — play the sound
      setState(() => _status = 'Réception terminée, lecture...');
      final ok = await _playBuffer();

      // Send confirmation via notify characteristic
      final response = ok ? utf8.encode("ok") : utf8.encode("err");
      try {
        await BlePeripheral.updateCharacteristic(
          characteristicId: kNotifyUuid,
          value: Uint8List.fromList(response),
          deviceId: deviceId,
        );
      } catch (e) {
        debugPrint('Erreur notification: $e');
      }

      _buffer = [];
    } else {
      _buffer.addAll(chunk);
      setState(() => _status = 'Réception: ${_buffer.length} octets...');
    }
  }

  Future<bool> _playBuffer() async {
    try {
      final dir  = await getTemporaryDirectory();
      final file = File('${dir.path}/recv_sound.mp3');
      await file.writeAsBytes(_buffer);

      // Force audio through the phone's speaker, not via Bluetooth
      await _player.setAudioContext(AudioContext(
        android: AudioContextAndroid(
          isSpeakerphoneOn: true,
          audioMode: AndroidAudioMode.normal,
          usageType: AndroidUsageType.alarm,
          contentType: AndroidContentType.sonification,
        ),
      ));

      await _player.play(DeviceFileSource(file.path));
      setState(() => _status = 'Son joué ✓');
      return true;
    } catch (e) {
      debugPrint('Erreur lecture son: $e');
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
            Icon(
              Icons.bluetooth,
              color: _advertising ? Colors.blueAccent : Colors.grey,
              size: 64,
            ),
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
    BlePeripheral.stopAdvertising();
    super.dispose();
  }
}
