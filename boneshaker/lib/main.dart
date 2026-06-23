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

  // --- 地图渲染与路网核心数据 ---
  List<Map<String, dynamic>> _allRidesData = []; // 保存所有原始骑行记录
  List<List<LatLng>> _cloudRouteLines = [];
  List<LatLng> _liveRoute = [];
  List<Map<String, dynamic>> _bumpData = [];

  // --- 寻路系统变量 ---
  Map<String, Map<String, double>> _graph = {};
  Map<String, LatLng> _nodes = {};
  bool _routingMode = false;
  int _routeStep = 0;
  String? _startNodeId;
  String? _endNodeId;
  LatLng? _startMarker;
  LatLng? _endMarker;
  List<LatLng> _optimalPath = [];
  String _routeToastText = "";

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

  // ================= 1. 实时云端监听与路网构建 =================
  void _listenToCloudData() {
    FirebaseFirestore.instance.collection('rides').snapshots().listen((
      snapshot,
    ) {
      List<Map<String, dynamic>> rawRides = [];
      List<List<LatLng>> allRouteLines = [];
      List<Map<String, dynamic>> allBumps = [];

      for (var doc in snapshot.docs) {
        var data = doc.data();
        rawRides.add(data);

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
        _allRidesData = rawRides;
        _cloudRouteLines = allRouteLines;
        _bumpData = allBumps;
      });

      _buildTopologyGraph(); // 每次数据更新，自动构建底层拓扑图

      if (_cloudRouteLines.isNotEmpty &&
          _cloudRouteLines.last.isNotEmpty &&
          !_isRecording &&
          !_routingMode) {
        _mapController.move(_cloudRouteLines.last.first, 16.0);
      }
    });
  }

  // ================= 2. 测距与构建虚拟缝合网络 =================
  double _calcDistKm(LatLng p1, LatLng p2) {
    const Distance distance = Distance();
    return distance.as(LengthUnit.Meter, p1, p2) / 1000.0;
  }

  void _buildTopologyGraph() {
    _graph.clear();
    _nodes.clear();

    for (var ride in _allRidesData) {
      var route = ride['route'] as List<dynamic>?;
      var bumps = ride['bumps'] as List<dynamic>?;
      if (route == null || route.length < 2) continue;

      List<double> pointPenalties = List.filled(route.length, 0.0);

      // 第一步：坑洼惩罚映射
      if (bumps != null) {
        for (var b in bumps) {
          double bLat = (b['lat'] as num).toDouble();
          double bLng = (b['lng'] as num).toDouble();
          String bType = b['type'];

          double minD = double.infinity;
          int minIdx = -1;
          for (int i = 0; i < route.length; i++) {
            double rLat = (route[i]['lat'] as num).toDouble();
            double rLng = (route[i]['lng'] as num).toDouble();
            double d = _calcDistKm(LatLng(rLat, rLng), LatLng(bLat, bLng));
            if (d < minD) {
              minD = d;
              minIdx = i;
            }
          }
          if (minIdx != -1) {
            pointPenalties[minIdx] += (bType == 'severe'
                ? 0.5
                : 0.2); // 重度绕路500米，中度绕路200米
          }
        }
      }

      String? prevNodeId;
      double accumulatedPenalty = 0;

      // 第二步：节点吸附与连线
      for (int i = 0; i < route.length; i++) {
        double rLat = (route[i]['lat'] as num).toDouble();
        double rLng = (route[i]['lng'] as num).toDouble();

        String nodeId =
            "${rLat.toStringAsFixed(4)}_${rLng.toStringAsFixed(4)}"; // 11米精度吸附
        _nodes[nodeId] = LatLng(rLat, rLng);
        accumulatedPenalty += pointPenalties[i];

        if (prevNodeId != null && prevNodeId != nodeId) {
          double dist = _calcDistKm(_nodes[prevNodeId]!, _nodes[nodeId]!);
          double weight = dist + accumulatedPenalty;

          _graph.putIfAbsent(prevNodeId, () => {});
          _graph.putIfAbsent(nodeId, () => {});

          if (!_graph[prevNodeId]!.containsKey(nodeId) ||
              weight < _graph[prevNodeId]![nodeId]!) {
            _graph[prevNodeId]![nodeId] = weight;
            _graph[nodeId]![prevNodeId] = weight;
          }
          prevNodeId = nodeId;
          accumulatedPenalty = 0;
        } else if (prevNodeId == null) {
          prevNodeId = nodeId;
        }
      }
    }

    // 第三步：虚拟缝合 (打通150米内的断头路)
    List<String> nodeArray = _nodes.keys.toList();
    for (int i = 0; i < nodeArray.length; i++) {
      String idA = nodeArray[i];
      LatLng ptA = _nodes[idA]!;
      for (int j = i + 1; j < nodeArray.length; j++) {
        String idB = nodeArray[j];
        LatLng ptB = _nodes[idB]!;

        if ((ptA.latitude - ptB.latitude).abs() > 0.002 ||
            (ptA.longitude - ptB.longitude).abs() > 0.003)
          continue;
        if (_graph[idA] != null && _graph[idA]!.containsKey(idB)) continue;

        double dist = _calcDistKm(ptA, ptB);
        if (dist < 0.15) {
          // 缝合距离上限 150m
          double weight = dist * 1.5; // 未知路段 1.5 倍惩罚
          _graph.putIfAbsent(idA, () => {});
          _graph.putIfAbsent(idB, () => {});
          _graph[idA]![idB] = weight;
          _graph[idB]![idA] = weight;
        }
      }
    }
  }

  // ================= 3. 戴克斯特拉寻路算法 =================
  List<LatLng> _findShortestPath(String startId, String endId) {
    Map<String, double> distances = {};
    Map<String, String> prev = {};
    Set<String> pq = {};

    for (var node in _graph.keys) {
      distances[node] = double.infinity;
      pq.add(node);
    }
    distances[startId] = 0.0;

    while (pq.isNotEmpty) {
      String? minNode;
      for (var node in pq) {
        if (minNode == null || distances[node]! < distances[minNode]!) {
          minNode = node;
        }
      }

      if (minNode == null ||
          distances[minNode] == double.infinity ||
          minNode == endId)
        break;
      pq.remove(minNode);

      _graph[minNode]?.forEach((neighbor, weight) {
        if (!pq.contains(neighbor)) return;
        double alt = distances[minNode]! + weight;
        if (alt < distances[neighbor]!) {
          distances[neighbor] = alt;
          prev[neighbor] = minNode!;
        }
      });
    }

    List<LatLng> pathCoords = [];
    String? curr = endId;
    if (prev.containsKey(curr) || curr == startId) {
      while (curr != null) {
        pathCoords.insert(0, _nodes[curr]!);
        curr = prev[curr];
      }
    }
    return pathCoords;
  }

  // ================= 4. 地图点击与交互逻辑 =================
  void _toggleRouteMode() {
    setState(() {
      _routingMode = !_routingMode;
      if (_routingMode) {
        _routeStep = 1;
        _optimalPath.clear();
        _startMarker = null;
        _endMarker = null;
        _routeToastText = "📍 Tap on map to set START...";
      } else {
        _routeStep = 0;
        _optimalPath.clear();
        _startMarker = null;
        _endMarker = null;
      }
    });
  }

  void _clearOptimalRoute() {
    setState(() {
      _optimalPath.clear();
      _startMarker = null;
      _endMarker = null;
      if (_routingMode) {
        _routeStep = 1;
        _routeToastText = "📍 Tap on map to set START...";
      }
    });
  }

  void _handleMapTap(LatLng point) {
    if (!_routingMode) return;

    String? closestNode;
    double minDist = double.infinity;

    _nodes.forEach((id, latlng) {
      double d = _calcDistKm(point, latlng);
      if (d < minDist) {
        minDist = d;
        closestNode = id;
      }
    });

    if (minDist > 0.2 || closestNode == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Too far from surveyed routes!")),
      );
      return;
    }

    if (_routeStep == 1) {
      setState(() {
        _optimalPath.clear();
        _startMarker = _nodes[closestNode];
        _endMarker = null;
        _startNodeId = closestNode;
        _routeStep = 2;
        _routeToastText = "🏁 Now tap to set DESTINATION...";
      });
    } else if (_routeStep == 2) {
      setState(() {
        _endMarker = _nodes[closestNode];
        _endNodeId = closestNode;
        _routeToastText = "⏳ Calculating optimal smooth route...";
      });

      Future.delayed(const Duration(milliseconds: 100), () {
        List<LatLng> bestPath = _findShortestPath(_startNodeId!, _endNodeId!);
        setState(() {
          if (bestPath.isNotEmpty) {
            _optimalPath = bestPath;
            _routeToastText = "✅ Route found! (Avoided severe bumps)";
          } else {
            _routeToastText = "⚠️ Path too far or disconnected.";
          }
          _routeStep = 1; // 允许立即点新起点
        });
      });
    }
  }

  // ================= 5. 数据采集与同步系统 =================
  // (保持原有的采集和清洗逻辑完全不变，确保测绘精度)
  Future<void> _clearCloudData() async {
    bool confirm =
        await showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text("Clear Cloud Data?"),
            content: const Text("This will delete ALL rides. Are you sure?"),
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
        DateTime? lastBumpTime;

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
    DateTime? lastBumpTime;

    for (var row in _dataLog) {
      String timeStr = row[0].toString();
      DateTime currentTime = DateTime.parse(timeStr);
      double accZ = double.tryParse(row[3].toString()) ?? -0.98;
      double lat = row[4];
      double lng = row[5];

      if (lat == 0.0 && lng == 0.0) continue;
      uploadRoute.add({'lat': lat, 'lng': lng});

      double dynamicZ = (accZ.abs() - 0.98).abs();
      if (dynamicZ >= 0.45) {
        if (lastBumpTime == null ||
            currentTime.difference(lastBumpTime).inMilliseconds > 1500) {
          uploadBumps.add({
            'lat': lat,
            'lng': lng,
            'impact': dynamicZ.toStringAsFixed(2),
            'type': dynamicZ >= 0.65 ? 'severe' : 'moderate',
          });
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

  // ================= 6. 地图图层精细化渲染 =================
  List<Polyline> _buildBasePolylines() {
    List<Polyline> lines = [];
    for (var singleLine in _cloudRouteLines) {
      lines.add(
        Polyline(
          points: singleLine,
          strokeWidth: 4.0,
          color: Colors.blueAccent.withOpacity(
            _routingMode ? 0.3 : 0.7,
          ), // 规划时虚化底图
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

  List<Polyline> _buildOptimalPolyline() {
    if (_optimalPath.isNotEmpty) {
      return [
        Polyline(
          points: _optimalPath,
          strokeWidth: 8.0,
          color: Colors.greenAccent[400]!,
        ),
      ];
    }
    return [];
  }

  List<Marker> _buildBumpMarkers() {
    List<Marker> markers = [];
    for (var bump in _bumpData) {
      bool isSevere = bump['type'] == 'severe';
      markers.add(
        Marker(
          point: LatLng(bump['lat'], bump['lng']),
          width: isSevere ? 20 : 12,
          height: isSevere ? 20 : 12,
          child: Icon(
            isSevere ? Icons.warning : Icons.circle,
            color: isSevere ? Colors.redAccent : Colors.orange,
            size: isSevere ? 20 : 12,
          ),
        ),
      );
    }
    return markers;
  }

  List<Marker> _buildRoutingMarkers() {
    List<Marker> markers = [
      Marker(
        point: LatLng(_currentLat, _currentLng),
        child: const Icon(Icons.my_location, color: Colors.blue, size: 25),
      ),
    ];
    if (_startMarker != null) {
      markers.add(
        Marker(
          point: _startMarker!,
          width: 40,
          height: 40,
          child: const Icon(Icons.location_pin, color: Colors.green, size: 40),
        ),
      );
    }
    if (_endMarker != null) {
      markers.add(
        Marker(
          point: _endMarker!,
          width: 40,
          height: 40,
          child: const Icon(Icons.location_pin, color: Colors.red, size: 40),
        ),
      );
    }
    return markers;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              "Bone-Shaker AI Route",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
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
          // 规划路线提示横幅
          if (_routingMode)
            Container(
              width: double.infinity,
              color: Colors.amber,
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _routeToastText,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.black,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),

          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(child: _buildInfoCard("GPS", gpsData, Colors.green)),
                const SizedBox(width: 8),
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
                onTap: (tapPosition, point) =>
                    _handleMapTap(point), // 核心：开启触控选点
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.boneshaker.app',
                ),
                // 图层严谨分离：确保绿线在下，红黄坑洼点和起终点图钉在最上层！
                PolylineLayer(polylines: _buildBasePolylines()),
                PolylineLayer(polylines: _buildOptimalPolyline()),
                MarkerLayer(markers: _buildBumpMarkers()),
                MarkerLayer(markers: _buildRoutingMarkers()),
              ],
            ),
          ),

          // --- 工业级控制面板排版 ---
          Container(
            padding: const EdgeInsets.all(10),
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
                const SizedBox(height: 8),

                // 第一排：云端与寻路功能
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _routingMode
                            ? _toggleRouteMode
                            : _toggleRouteMode,
                        icon: Icon(_routingMode ? Icons.close : Icons.map),
                        label: Text(
                          _routingMode ? "CANCEL" : "PLAN ROUTE",
                          style: const TextStyle(fontSize: 12),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _routingMode
                              ? Colors.red[400]
                              : Colors.purple,
                          foregroundColor: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _clearOptimalRoute,
                        icon: const Icon(Icons.cleaning_services),
                        label: const Text(
                          "CLEAR LINE",
                          style: TextStyle(fontSize: 12),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.greenAccent[400],
                          foregroundColor: Colors.black,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),

                // 第二排：基础采集控制
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _isRecording ? null : _clearCloudData,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.grey[700],
                          foregroundColor: Colors.white,
                        ),
                        child: const Icon(Icons.delete_outline),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _isRecording
                            ? null
                            : _importCsvAndUploadToCloud,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.indigo,
                          foregroundColor: Colors.white,
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
                        ),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        onPressed: !_isRecording ? null : _stopRecordAndSync,
                        icon: const Icon(Icons.stop, size: 18),
                        label: const Text(
                          "SAVE & SYNC",
                          style: TextStyle(fontSize: 11),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red[600],
                          foregroundColor: Colors.white,
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
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        border: Border.all(color: color.withOpacity(0.5), width: 1.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.bold,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            content,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}
