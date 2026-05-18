import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart'; // 新增：用于识别当前的操作系统平台
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:csv/csv.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

void main() => runApp(
  const MaterialApp(
    home: SensorDisplayApp(),
    debugShowCheckedModeBanner: false,
  ),
);

class SensorDisplayApp extends StatefulWidget {
  const SensorDisplayApp({super.key});

  @override
  State<SensorDisplayApp> createState() => _SensorDisplayAppState();
}

class _SensorDisplayAppState extends State<SensorDisplayApp> {
  // UI Display States
  String accelData = "Waiting for BLE...";
  String gpsData = "Fetching GPS...";
  String debugLog = "System Ready.\n";

  // Recording States
  bool _isRecording = false;
  final List<List<dynamic>> _dataLog = [];

  // Current GPS Cache
  double _currentLat = 0.0;
  double _currentLng = 0.0;

  // UUIDs
  final String serviceUuid = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
  final String txUuid = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";

  @override
  void initState() {
    super.initState();
    _startSystem();
  }

  Future<void> _startSystem() async {
    await _requestPermissions();
    _initGps();
    _initBluetooth();
  }

  // --- 1. Permissions ---
  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location,
        Permission.storage, // For saving CSV on older Androids
      ].request();
    }
  }

  // --- 2. GPS Logic (强制 1Hz 刷新版) ---
  void _initGps() {
    late LocationSettings locationSettings;

    if (defaultTargetPlatform == TargetPlatform.android) {
      // 针对 Android 的强制高频刷新配置
      locationSettings = AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 1), // 强制 1 秒返回一次
      );
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      // 针对 iOS 的运动追踪配置
      locationSettings = AppleSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        activityType: ActivityType.fitness,
        distanceFilter: 0,
      );
    } else {
      locationSettings = const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
      );
    }

    Geolocator.getPositionStream(locationSettings: locationSettings).listen((
      Position position,
    ) {
      _currentLat = position.latitude;
      _currentLng = position.longitude;
      setState(() {
        gpsData =
            "Lat: ${_currentLat.toStringAsFixed(6)}\nLong: ${_currentLng.toStringAsFixed(6)}";
      });
    });
  }

  // --- 3. Bluetooth Logic ---
  void _initBluetooth() async {
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      _updateLog("Error: Turn on Bluetooth");
      return;
    }

    _updateLog("Scanning for ESP32...");
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));

    FlutterBluePlus.scanResults.listen((results) async {
      for (ScanResult r in results) {
        String name = r.device.platformName;
        if (name == "ESP32_S3_IMU" || name.contains("ESP32")) {
          FlutterBluePlus.stopScan();
          _updateLog("Found $name! Connecting...");

          try {
            await r.device.connect();
            _updateLog("Connected. Discovering services...");
            _discoverServices(r.device);
          } catch (e) {
            _updateLog("Connection Failed: $e");
          }
          break;
        }
      }
    });
  }

  void _discoverServices(BluetoothDevice device) async {
    try {
      List<BluetoothService> services = await device.discoverServices();
      for (var s in services) {
        if (s.uuid.toString().toUpperCase() == serviceUuid) {
          for (var c in s.characteristics) {
            if (c.uuid.toString().toUpperCase() == txUuid) {
              _updateLog("Data stream linked. Receiving data...");
              await c.setNotifyValue(true);

              c.onValueReceived.listen((value) {
                String rawStr = utf8.decode(value);
                setState(() => accelData = rawStr);

                if (_isRecording) {
                  _processAndRecordData(rawStr);
                }
              });
            }
          }
        }
      }
    } catch (e) {
      _updateLog("Service Error: $e");
    }
  }

  // --- 4. Data Processing (Regex Split) ---
  void _processAndRecordData(String rawAccel) {
    DateTime now = DateTime.now();
    String valX = "0.0", valY = "0.0", valZ = "0.0";

    try {
      // Extract floating point numbers using Regex
      RegExp regExp = RegExp(r'[-+]?\d*\.?\d+');
      List<RegExpMatch> matches = regExp.allMatches(rawAccel).toList();

      if (matches.length >= 3) {
        valX = matches[0].group(0) ?? "0.0";
        valY = matches[1].group(0) ?? "0.0";
        valZ = matches[2].group(0) ?? "0.0";
      } else {
        valX = rawAccel; // Fallback if format changes
      }
    } catch (e) {
      print("Parse Error: $e");
    }

    _dataLog.add([
      now.toIso8601String(),
      valX,
      valY,
      valZ,
      _currentLat,
      _currentLng,
    ]);
  }

  // --- 5. CSV Export ---
  Future<void> _saveAndShareCsv() async {
    if (_dataLog.isEmpty) {
      _updateLog("Warning: No data recorded to save.");
      return;
    }

    _updateLog("Generating CSV...");

    // Create Header
    List<List<dynamic>> csvData = [
      ["Timestamp", "Acc_X", "Acc_Y", "Acc_Z", "Latitude", "Longitude"],
    ];
    csvData.addAll(_dataLog);

    String csvString = const ListToCsvConverter().convert(csvData);

    try {
      final directory = await getTemporaryDirectory();
      final path =
          "${directory.path}/road_data_${DateTime.now().millisecondsSinceEpoch}.csv";
      final file = File(path);
      await file.writeAsString(csvString);

      _updateLog("CSV Saved. Opening share menu...");
      await Share.shareXFiles([
        XFile(path),
      ], text: 'Exported Road Quality Data');
    } catch (e) {
      _updateLog("Save Error: $e");
    }

    setState(() {
      _dataLog.clear();
    });
  }

  void _updateLog(String msg) {
    print(msg);
    setState(() {
      debugLog += "$msg\n";
    });
  }

  // --- 6. UI Rendering ---
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Data Logger Dashboard"),
        backgroundColor: Colors.blueGrey[800],
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Status Cards
            Row(
              children: [
                Expanded(child: _buildInfoCard("GPS", gpsData, Colors.green)),
                const SizedBox(width: 10),
                Expanded(child: _buildInfoCard("IMU", accelData, Colors.blue)),
              ],
            ),
            const SizedBox(height: 20),

            // Console Output
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                "Console Log",
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.grey,
                ),
              ),
            ),
            const SizedBox(height: 5),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SingleChildScrollView(
                  reverse: true,
                  child: Text(
                    debugLog,
                    style: const TextStyle(
                      color: Colors.lightGreenAccent,
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Record Status
            Text(
              _isRecording
                  ? "🔴 RECORDING IN PROGRESS (${_dataLog.length} rows)"
                  : "⚪ IDLE",
              style: TextStyle(
                color: _isRecording ? Colors.red : Colors.grey,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 15),

            // Control Buttons
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isRecording
                        ? null
                        : () {
                            setState(() {
                              _isRecording = true;
                              _dataLog.clear();
                              _updateLog("--- Recording Started ---");
                            });
                          },
                    icon: const Icon(Icons.play_arrow),
                    label: const Text("START", style: TextStyle(fontSize: 18)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green[600],
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                    ),
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: !_isRecording
                        ? null
                        : () {
                            setState(() {
                              _isRecording = false;
                              _updateLog("--- Recording Stopped ---");
                            });
                            _saveAndShareCsv();
                          },
                    icon: const Icon(Icons.stop),
                    label: const Text(
                      "STOP & SAVE",
                      style: TextStyle(fontSize: 18),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red[600],
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoCard(String title, String content, Color color) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        border: Border.all(color: color.withOpacity(0.5), width: 2),
        borderRadius: BorderRadius.circular(15),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            content,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}
