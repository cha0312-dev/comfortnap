// import 'dart:async';
// import 'dart:convert';
// import 'package:flutter_blue_plus/flutter_blue_plus.dart';

// class BLEManager {
//   BLEManager._privateConstructor();
//   static final BLEManager instance = BLEManager._privateConstructor();

//   BluetoothDevice? _device;
//   BluetoothCharacteristic? _rxCharacteristic;
//   BluetoothCharacteristic? _txCharacteristic;

//   bool connected = false;
//   BluetoothDevice? lastDevice;

//   // 🔔 Stream to notify UI about connection changes
//   final _connectionController = StreamController<bool>.broadcast();
//   Stream<bool> get connectionStream => _connectionController.stream;

//   // Service + characteristic UUIDs (parehas sa Arduino)
//   static const String SERVICE_UUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
//   static const String CHAR_TX = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"; // ESP32 → phone
//   static const String CHAR_RX = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"; // phone → ESP32

//   Future<void> connect(BluetoothDevice device) async {
//     _device = device;
//     lastDevice = device;

//     try {
//       await _device!.connect(autoConnect: false);
//     } catch (e) {
//       if (e.toString().contains("already connected")) {
//         print("Already connected");
//       } else {
//         print("Connection error: $e");
//       }
//     }

//     // Listen for disconnects
//     _device!.connectionState.listen((state) {
//       if (state == BluetoothConnectionState.disconnected) {
//         connected = false;
//         _connectionController.add(false); // notify UI
//         print("Device disconnected unexpectedly");
//       }
//     });

//     // Discover services
//     List<BluetoothService> services = await _device!.discoverServices();
//     for (var s in services) {
//       if (s.uuid.toString().toUpperCase() == SERVICE_UUID) {
//         for (var c in s.characteristics) {
//           final uuid = c.uuid.toString().toUpperCase();

//           if (uuid == CHAR_TX) {
//             _txCharacteristic = c;
//             await c.setNotifyValue(true);
//             c.value.listen((data) {
//               final text = utf8.decode(data);
//               print("ESP32 → $text");
//             });
//           }

//           if (uuid == CHAR_RX) {
//             _rxCharacteristic = c;
//           }
//         }
//       }
//     }

//     // ✅ Basta naa ang RX, consider connected
//     if (_rxCharacteristic != null) {
//       connected = true;
//       _connectionController.add(true); // notify UI
//       print("BLE connected to ${_device!.name}");
//     } else {
//       connected = false;
//       _connectionController.add(false);
//       print("Failed: RX characteristic not found!");
//     }
//   }

//   Future<void> send(String message) async {
//     if (!connected) {
//       print("❌ Device not connected!");
//       return;
//     }
//     if (_rxCharacteristic == null) {
//       print("❌ RX characteristic not found!");
//       return;
//     }
//     final bytes = utf8.encode(message);
//     try {
//       await _rxCharacteristic!.write(bytes, withoutResponse: false);
//       print("✅ You → $message");
//     } catch (e) {
//       print("❌ Failed to send: $e");
//     }
//   }

//   Future<void> autoConnect() async {
//     if (lastDevice != null) {
//       await connect(lastDevice!);
//     } else {
//       print("No previously connected device found.");
//     }
//   }

//   Future<void> disconnect() async {
//     if (_device != null) {
//       try {
//         if (_txCharacteristic != null) {
//           await _txCharacteristic!.setNotifyValue(false);
//         }
//         await _device!.disconnect();
//       } catch (e) {
//         print("Error during disconnect: $e");
//       }
//       connected = false;
//       _connectionController.add(false); // notify UI
//       _device = null;
//       _rxCharacteristic = null;
//       _txCharacteristic = null;
//       print("Device disconnected");
//     }
//   }

//   void dispose() {
//     _connectionController.close();
//   }
// }

import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class BLEManager {
  BLEManager._();
  static final BLEManager instance = BLEManager._();

  BluetoothDevice? _device;
  BluetoothCharacteristic? _rx;

  bool connected = false;

  // ================= STREAMS =================
  final _stream = StreamController<bool>.broadcast();
  Stream<bool> get connectionStream => _stream.stream;

  final _sleepStream = StreamController<String>.broadcast();
  Stream<String> get sleepStream => _sleepStream.stream;

  final _temperatureStream = StreamController<double>.broadcast();
  Stream<double> get temperatureStream => _temperatureStream.stream;

  final _heaterSafetyStream = StreamController<String>.broadcast();
  Stream<String> get heaterSafetyStream => _heaterSafetyStream.stream;

  // ================= UUID =================
  static const serviceUUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
  static const txUUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";
  static const rxUUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E";

  // ================= CONNECT =================
  Future<void> connect(BluetoothDevice device) async {
    _device = device;

    await _device!.connect(autoConnect: false);

    _device!.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        connected = false;
        _stream.add(false);
      }
    });

    var services = await _device!.discoverServices();

    for (var s in services) {
      if (s.uuid.toString().toUpperCase() == serviceUUID) {
        for (var c in s.characteristics) {
          // ================= TX (NOTIFY FROM ESP32) =================
          if (c.uuid.toString().toUpperCase() == txUUID) {
            await c.setNotifyValue(true);

            c.value.listen((data) {
              final msg = utf8.decode(data).trim();
              print("ESP32: $msg");

              if (msg.startsWith("TEMP:") || msg.startsWith("PILLOW_TEMP:")) {
                final raw = msg.contains(":")
                    ? msg.split(":").sublist(1).join(":")
                    : msg;

                try {
                  final temperature = double.parse(raw);
                  _temperatureStream.add(temperature);
                } catch (_) {
                  print("INVALID TEMP PAYLOAD: $msg");
                }
              }
              // ================= HEATER SAFETY =================
              else if (msg.startsWith("SAFETY:")) {
                _heaterSafetyStream.add(msg.substring("SAFETY:".length));
              }
              // ================= SLEEP DATA =================
              else if (msg.startsWith("SLEEP:")) {
                _sleepStream.add(msg);
              }
            });
          }

          // ================= RX (SEND TO ESP32) =================
          if (c.uuid.toString().toUpperCase() == rxUUID) {
            _rx = c;
          }
        }
      }
    }

    connected = _rx != null;
    _stream.add(connected);
  }

  // ================= SEND COMMAND =================
  Future<void> send(String msg) async {
    if (!connected || _rx == null) return;
    await _rx!.write(utf8.encode(msg));
  }

  // ================= DISCONNECT =================
  Future<void> disconnect() async {
    try {
      await _device?.disconnect();
    } catch (e) {
      print("DISCONNECT ERROR: $e");
    }

    connected = false;
    _stream.add(false);

    _device = null;
    _rx = null;
  }

  // ================= CLEANUP =================
  void dispose() {
    _stream.close();
    _sleepStream.close();
    _temperatureStream.close();
    _heaterSafetyStream.close();
  }
}
