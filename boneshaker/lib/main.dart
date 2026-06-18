import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:csv/csv.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:file_picker/file_picker.dart';

// Firebase 核心依赖
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  runApp(
    const MaterialApp(
      home: SensorDisplayApp(),
      debugShowCheckedModeBanner: false,
    ),
  );
}

class SensorDisplayApp extends StatefulWidget {
  const SensorDisplayApp({super.key});

  @override
  State<SensorDisplayApp> createState() => _SensorDisplayAppState();
}

class _SensorDisplayAppState extends State<SensorDisplayApp> {
  String accelData = "Waiting for BLE...";
  String gpsData = "Fetching GPS...";
  String syncStatus = "🟢 Live Sync Active";

  bool _isRecording = false;
  final List<List<dynamic>> _dataLog = [];

  double _currentLat = 51.536;
  double _currentLng = -0.012;

  final MapController _mapController = MapController();

  // --- 地图渲染数据：嵌套数组解决折线相连问题 ---
  List<List<LatLng>> _cloudRouteLines = []; // 云端的历史路线
  List<LatLng> _liveRoute = []; // 正在录制的当前路线
  List<Map<String, dynamic>> _bumpData = [];

  final String serviceUuid = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
  final String txUuid = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";

  @override
  void initState() {
    super.initState();
    _startSystem();
  }

  Future<void> _startSystem() async {
    _listenToCloudData();
    await _requestPermissions();
    _initGps();
    _initBluetooth();
  }

  // ================= 1. 实时云端监听 =================
  void _listenToCloudData() {
    FirebaseFirestore.instance.collection('rides').snapshots().listen((
      snapshot,
    ) {
      List<List<LatLng>> allRouteLines = [];
      List<Map<String, dynamic>> allBumps = [];

      for (var doc in snapshot.docs) {
        var data = doc.data();

        if (data['route'] != null) {
          List<LatLng> singleRide = [];
          for (var pt in data['route']) {
            singleRide.add(LatLng(pt['lat'] + 0.0, pt['lng'] + 0.0));
          }
          if (singleRide.isNotEmpty) allRouteLines.add(singleRide);
        }

        if (data['bumps'] != null) {
          for (var b in data['bumps']) {
            allBumps.add({
              'lat': b['lat'] + 0.0,
              'lng': b['lng'] + 0.0,
              'type': b['type'],
            });
          }
        }
      }

      setState(() {
        _cloudRouteLines = allRouteLines;
        _bumpData = allBumps;
      });

      if (_cloudRouteLines.isNotEmpty &&
          _cloudRouteLines.last.isNotEmpty &&
          !_isRecording) {
        _mapController.move(_cloudRouteLines.last.first, 16.0);
      }
    });
  }

  Future<void> _clearCloudData() async {
    bool confirm =
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text("Clear Cloud Data?"),
            content: const Text(
              "This will delete ALL rides from the cloud. Are you sure?",
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text("CANCEL"),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text(
                  "DELETE",
                  style: TextStyle(color: Colors.red),
                ),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirm) return;

    setState(() => syncStatus = "⏳ Deleting...");
    var snapshots = await FirebaseFirestore.instance.collection('rides').get();
    for (var doc in snapshots.docs) {
      await doc.reference.delete();
    }
    setState(() => syncStatus = "🟢 Live Sync Active");
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.location,
        Permission.storage,
      ].request();
    }
  }

  void _initGps() {
    late LocationSettings locationSettings;
    if (defaultTargetPlatform == TargetPlatform.android) {
      locationSettings = AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 1),
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
      setState(() {
        _currentLat = position.latitude;
        _currentLng = position.longitude;
        gpsData =
            "Lat: ${_currentLat.toStringAsFixed(5)}\nLong: ${_currentLng.toStringAsFixed(5)}";

        if (_isRecording) {
          _liveRoute.add(LatLng(_currentLat, _currentLng));
          _mapController.move(LatLng(_currentLat, _currentLng), 17.0);
        }
      });
    });
  }

  void _initBluetooth() async {
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on)
      return;
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
    FlutterBluePlus.scanResults.listen((results) async {
      for (ScanResult r in results) {
        if (r.device.platformName.contains("ESP32")) {
          FlutterBluePlus.stopScan();
          try {
            await r.device.connect();
            _discoverServices(r.device);
          } catch (e) {}
          break;
        }
      }
    });
  }

  void _discoverServices(BluetoothDevice device) async {
    List<BluetoothService> services = await device.discoverServices();
    for (var s in services) {
      if (s.uuid.toString().toUpperCase() == serviceUuid) {
        for (var c in s.characteristics) {
          if (c.uuid.toString().toUpperCase() == txUuid) {
            await c.setNotifyValue(true);
            c.onValueReceived.listen((value) {
              String rawStr = utf8.decode(value);
              setState(() => accelData = rawStr);
              if (_isRecording) _processAndRecordData(rawStr);
            });
          }
        }
      }
    }
  }

  void _processAndRecordData(String rawAccel) {
    DateTime now = DateTime.now();
    String valX = "0.0", valY = "0.0", valZ = "0.0";
    try {
      RegExp regExp = RegExp(r'[-+]?\d*\.?\d+');
      List<RegExpMatch> matches = regExp.allMatches(rawAccel).toList();
      if (matches.length >= 3) {
        valX = matches[0].group(0) ?? "0.0";
        valY = matches[1].group(0) ?? "0.0";
        valZ = matches[2].group(0) ?? "0.0";
      } else {
        valX = rawAccel;
      }
    } catch (e) {}
    _dataLog.add([
      now.toIso8601String(),
      valX,
      valY,
      valZ,
      _currentLat,
      _currentLng,
    ]);
  }

  // ================= 导入 CSV (应用全新阈值 + 防抖) =================
  Future<void> _importCsvAndUploadToCloud() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
      );

      if (result != null) {
        setState(() => syncStatus = "⏳ Uploading...");
        File file = File(result.files.single.path!);
        final csvString = await file.readAsString();
        List<List<dynamic>> rowsAsListOfValues = const CsvToListConverter()
            .convert(csvString);

        List<Map<String, double>> uploadRoute = [];
        List<Map<String, dynamic>> uploadBumps = [];
        DateTime? lastBumpTime; // 🔥新增防抖计时器

        for (int i = 1; i < rowsAsListOfValues.length; i++) {
          var row = rowsAsListOfValues[i];
          if (row.length >= 6) {
            String timeStr = row[0].toString();
            DateTime currentTime = DateTime.parse(timeStr);
            double accZ = double.tryParse(row[3].toString()) ?? -0.98;
            double lat = double.tryParse(row[4].toString()) ?? 0.0;
            double lng = double.tryParse(row[5].toString()) ?? 0.0;

            if (lat == 0.0 && lng == 0.0) continue;
            uploadRoute.add({'lat': lat, 'lng': lng});

            double dynamicZ = (accZ.abs() - 0.98).abs();

            // 🔥核心防抖判定 (1500毫秒)
            if (dynamicZ >= 0.45) {
              if (lastBumpTime == null ||
                  currentTime.difference(lastBumpTime).inMilliseconds > 1500) {
                if (dynamicZ >= 0.65) {
                  uploadBumps.add({
                    'lat': lat,
                    'lng': lng,
                    'impact': dynamicZ.toStringAsFixed(2),
                    'type': 'severe',
                  });
                } else {
                  uploadBumps.add({
                    'lat': lat,
                    'lng': lng,
                    'impact': dynamicZ.toStringAsFixed(2),
                    'type': 'moderate',
                  });
                }
                lastBumpTime = currentTime;
              }
            }
          }
        }

        await FirebaseFirestore.instance.collection('rides').add({
          'timestamp': DateTime.now().toIso8601String(),
          'route': uploadRoute,
          'bumps': uploadBumps,
        });

        setState(() => syncStatus = "🟢 Live Sync Active");
      }
    } catch (e) {
      setState(() => syncStatus = "🔴 Upload Failed");
    }
  }

  // ================= 结束录制与同步 (应用全新阈值 + 防抖) =================
  Future<void> _stopRecordAndSync() async {
    if (_dataLog.isEmpty) return;

    setState(() {
      _isRecording = false;
      syncStatus = "⏳ Uploading to Cloud...";
    });

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
      await Share.shareXFiles([
        XFile(path),
      ], text: 'Exported Road Quality Data');
    } catch (e) {}

    List<Map<String, double>> uploadRoute = [];
    List<Map<String, dynamic>> uploadBumps = [];
    DateTime? lastBumpTime; // 🔥新增防抖计时器

    for (var row in _dataLog) {
      String timeStr = row[0].toString();
      DateTime currentTime = DateTime.parse(timeStr);
      double accZ = double.tryParse(row[3].toString()) ?? -0.98;
      double lat = row[4];
      double lng = row[5];

      if (lat == 0.0 && lng == 0.0) continue;
      uploadRoute.add({'lat': lat, 'lng': lng});

      double dynamicZ = (accZ.abs() - 0.98).abs();

      // 🔥核心防抖判定 (1500毫秒)
      if (dynamicZ >= 0.45) {
        if (lastBumpTime == null ||
            currentTime.difference(lastBumpTime).inMilliseconds > 1500) {
          if (dynamicZ >= 0.65) {
            uploadBumps.add({
              'lat': lat,
              'lng': lng,
              'impact': dynamicZ.toStringAsFixed(2),
              'type': 'severe',
            });
          } else {
            uploadBumps.add({
              'lat': lat,
              'lng': lng,
              'impact': dynamicZ.toStringAsFixed(2),
              'type': 'moderate',
            });
          }
          lastBumpTime = currentTime;
        }
      }
    }

    try {
      await FirebaseFirestore.instance.collection('rides').add({
        'timestamp': DateTime.now().toIso8601String(),
        'route': uploadRoute,
        'bumps': uploadBumps,
      });
      setState(() {
        syncStatus = "🟢 Live Sync Active";
        _liveRoute.clear();
      });
    } catch (e) {
      setState(() => syncStatus = "🔴 Sync Failed");
    }

    _dataLog.clear();
  }

  // 生成所有图钉
  List<Marker> _buildMapMarkers() {
    List<Marker> markers = [
      Marker(
        point: LatLng(_currentLat, _currentLng),
        child: const Icon(Icons.my_location, color: Colors.blue, size: 25),
      ),
    ];

    for (var bump in _bumpData) {
      bool isSevere = bump['type'] == 'severe';
      markers.add(
        Marker(
          point: LatLng(bump['lat'], bump['lng']),
          width: isSevere ? 30 : 15,
          height: isSevere ? 30 : 15,
          child: Icon(
            isSevere ? Icons.warning : Icons.circle,
            color: isSevere ? Colors.redAccent : Colors.orange,
            size: isSevere ? 30 : 15,
          ),
        ),
      );
    }
    return markers;
  }

  List<Polyline> _buildPolylines() {
    List<Polyline> lines = [];
    for (var singleLine in _cloudRouteLines) {
      lines.add(
        Polyline(
          points: singleLine,
          strokeWidth: 4.0,
          color: Colors.blueAccent.withOpacity(0.6),
        ),
      );
    }
    if (_isRecording && _liveRoute.isNotEmpty) {
      lines.add(
        Polyline(
          points: _liveRoute,
          strokeWidth: 5.0,
          color: Colors.cyanAccent,
        ),
      );
    }
    return lines;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text("Bone-Shaker Map", style: TextStyle(fontSize: 18)),
            Text(
              syncStatus,
              style: const TextStyle(fontSize: 12, color: Colors.greenAccent),
            ),
          ],
        ),
        backgroundColor: Colors.blueGrey[900],
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(10.0),
            child: Row(
              children: [
                Expanded(child: _buildInfoCard("GPS", gpsData, Colors.green)),
                const SizedBox(width: 10),
                Expanded(child: _buildInfoCard("IMU", accelData, Colors.blue)),
              ],
            ),
          ),

          Expanded(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: LatLng(_currentLat, _currentLng),
                initialZoom: 16.0,
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.boneshaker.app',
                ),
                PolylineLayer(polylines: _buildPolylines()),
                MarkerLayer(markers: _buildMapMarkers()),
              ],
            ),
          ),

          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.white,
            child: Column(
              children: [
                Text(
                  _isRecording
                      ? "🔴 RECORDING (${_dataLog.length} pts)"
                      : "⚪ MAP IDLE",
                  style: TextStyle(
                    color: _isRecording ? Colors.red : Colors.grey,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      flex: 1,
                      child: ElevatedButton(
                        onPressed: _isRecording ? null : _clearCloudData,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.grey[700],
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                        ),
                        child: const Icon(Icons.delete_outline),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      flex: 1,
                      child: ElevatedButton(
                        onPressed: _isRecording
                            ? null
                            : _importCsvAndUploadToCloud,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.indigo,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                        ),
                        child: const Icon(Icons.cloud_upload),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        onPressed: _isRecording
                            ? null
                            : () {
                                setState(() {
                                  _isRecording = true;
                                  _dataLog.clear();
                                  _liveRoute.clear();
                                });
                              },
                        icon: const Icon(Icons.play_arrow, size: 18),
                        label: const Text("START"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green[600],
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                        ),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        onPressed: !_isRecording ? null : _stopRecordAndSync,
                        icon: const Icon(Icons.stop, size: 18),
                        label: const Text("SAVE & SYNC"),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red[600],
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoCard(String title, String content, Color color) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        border: Border.all(color: color.withOpacity(0.5), width: 1.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            content,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}
