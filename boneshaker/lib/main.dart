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

// 地图与文件读取依赖
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:file_picker/file_picker.dart';
// 新增的本地缓存依赖
import 'package:shared_preferences/shared_preferences.dart';

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
  String accelData = "Waiting for BLE...";
  String gpsData = "Fetching GPS...";

  bool _isRecording = false;
  final List<List<dynamic>> _dataLog = [];

  double _currentLat = 51.536;
  double _currentLng = -0.012;

  final MapController _mapController = MapController();

  // --- 持久化地图状态 ---
  List<LatLng> _routePoints = [];
  List<Map<String, dynamic>> _bumpData = []; // 用于存储可序列化的坑洼数据

  final String serviceUuid = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
  final String txUuid = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";

  @override
  void initState() {
    super.initState();
    _startSystem();
  }

  Future<void> _startSystem() async {
    await _loadMapState(); // 第一步：先读取本地缓存的地图数据
    await _requestPermissions();
    _initGps();
    _initBluetooth();
  }

  // ================= 1. 数据持久化逻辑 =================

  // 保存当前地图数据到手机本地
  Future<void> _saveMapState() async {
    final prefs = await SharedPreferences.getInstance();

    // 保存轨迹线
    List<Map<String, double>> routeJson = _routePoints
        .map((p) => {'lat': p.latitude, 'lng': p.longitude})
        .toList();
    await prefs.setString('saved_route', jsonEncode(routeJson));

    // 保存坑洼点
    await prefs.setString('saved_bumps', jsonEncode(_bumpData));
  }

  // 从手机本地读取地图数据
  Future<void> _loadMapState() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      String? routeStr = prefs.getString('saved_route');
      if (routeStr != null) {
        List<dynamic> decoded = jsonDecode(routeStr);
        _routePoints = decoded.map((e) => LatLng(e['lat'], e['lng'])).toList();
      }

      String? bumpsStr = prefs.getString('saved_bumps');
      if (bumpsStr != null) {
        List<dynamic> decoded = jsonDecode(bumpsStr);
        _bumpData = decoded.map((e) => Map<String, dynamic>.from(e)).toList();
      }

      // 如果有保存的数据，将地图初始中心点设为轨迹的起点
      if (_routePoints.isNotEmpty) {
        _currentLat = _routePoints.first.latitude;
        _currentLng = _routePoints.first.longitude;
      }

      setState(() {});
    } catch (e) {
      print("Load Map State Error: $e");
    }
  }

  // 清除地图上的所有数据
  Future<void> _clearMapState() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('saved_route');
    await prefs.remove('saved_bumps');

    setState(() {
      _routePoints.clear();
      _bumpData.clear();
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Map data cleared!'),
        backgroundColor: Colors.red,
      ),
    );
  }

  // ======================================================

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
          _routePoints.add(LatLng(_currentLat, _currentLng));
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
        String name = r.device.platformName;
        if (name == "ESP32_S3_IMU" || name.contains("ESP32")) {
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

  Future<void> _importCsvAndPlot() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
      );

      if (result != null) {
        File file = File(result.files.single.path!);
        final csvString = await file.readAsString();
        List<List<dynamic>> rowsAsListOfValues = const CsvToListConverter()
            .convert(csvString);

        List<LatLng> importedRoute = [];
        List<Map<String, dynamic>> importedBumps = [];

        for (int i = 1; i < rowsAsListOfValues.length; i++) {
          var row = rowsAsListOfValues[i];
          if (row.length >= 6) {
            double accZ = double.tryParse(row[3].toString()) ?? -0.98;
            double lat = double.tryParse(row[4].toString()) ?? 0.0;
            double lng = double.tryParse(row[5].toString()) ?? 0.0;

            if (lat == 0.0 && lng == 0.0) continue;
            LatLng point = LatLng(lat, lng);

            if (importedRoute.isEmpty || importedRoute.last != point) {
              importedRoute.add(point);
            }

            double dynamicZ = (accZ.abs() - 0.98).abs();

            if (dynamicZ >= 0.45) {
              importedBumps.add({'lat': lat, 'lng': lng, 'type': 'severe'});
            } else if (dynamicZ >= 0.30 && dynamicZ < 0.45) {
              importedBumps.add({'lat': lat, 'lng': lng, 'type': 'moderate'});
            }
          }
        }

        setState(() {
          _routePoints = importedRoute;
          _bumpData = importedBumps;
        });

        // 导入成功后，触发保存逻辑
        await _saveMapState();

        if (importedRoute.isNotEmpty) {
          _mapController.move(importedRoute.first, 18.0);
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Load Success: Found ${importedBumps.length} bumps!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      print("Import Error: $e");
    }
  }

  Future<void> _saveAndShareCsv() async {
    if (_dataLog.isEmpty) return;
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

    setState(() => _dataLog.clear());
  }

  // 动态生成 Marker 图标集合
  List<Marker> _buildMapMarkers() {
    List<Marker> markers = [
      // 当前位置的蓝点
      Marker(
        point: LatLng(_currentLat, _currentLng),
        child: const Icon(Icons.my_location, color: Colors.blue, size: 25),
      ),
    ];

    // 添加所有缓存的颠簸点
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Bone-Shaker Map"),
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
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: _routePoints,
                      strokeWidth: 4.0,
                      color: Colors.blueAccent.withOpacity(0.7),
                    ),
                  ],
                ),
                MarkerLayer(
                  markers: _buildMapMarkers(), // 调用动态生成的标记函数
                ),
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
                    // --- 清除按钮 (垃圾桶) ---
                    Expanded(
                      flex: 1,
                      child: ElevatedButton(
                        onPressed: _isRecording ? null : _clearMapState,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.grey[700],
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                        ),
                        child: const Icon(Icons.delete_outline),
                      ),
                    ),
                    const SizedBox(width: 5),
                    // --- 导入按钮 (文件上传) ---
                    Expanded(
                      flex: 1,
                      child: ElevatedButton(
                        onPressed: _isRecording ? null : _importCsvAndPlot,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.indigo,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 15),
                        ),
                        child: const Icon(Icons.file_upload),
                      ),
                    ),
                    const SizedBox(width: 5),
                    // --- 开始按钮 ---
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        onPressed: _isRecording
                            ? null
                            : () {
                                setState(() {
                                  _isRecording = true;
                                  _dataLog.clear();
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
                    // --- 停止与保存按钮 ---
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        onPressed: !_isRecording
                            ? null
                            : () {
                                setState(() => _isRecording = false);
                                _saveAndShareCsv();
                              },
                        icon: const Icon(Icons.stop, size: 18),
                        label: const Text("SAVE"),
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
