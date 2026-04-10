import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:pitwatch/models/pothole.dart';
import 'package:pitwatch/providers/pothole_provider.dart';
import 'sessionCompleteScreen.dart';

class SessionScreen extends ConsumerStatefulWidget {
  final Duration? sessionDuration;

  const SessionScreen({super.key, this.sessionDuration});

  @override
  ConsumerState<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends ConsumerState<SessionScreen> {
  CameraController? _controller;
  Future<void>? _initializeFuture;
  Timer? _periodicTimer;
  Timer? _sessionTimer;
  Timer? _uiUpdateTimer;

  DateTime? _sessionStart;
  Position? _sessionStartPosition;
  Position? _sessionEndPosition;

  Interpreter? _interpreter;
  late List<int> _inputShape;
  late TensorType _inputType;
  List<String> _labels = [];
  bool _modelLoaded = false;
  bool _isProcessing = false;

  List<PotholeDetection> _sessionDetections = [];
  static const double _detectionThreshold = 0.9;
  static const double _nmsIouThreshold = 0.45;
  int _hazardsCount = 0;
  bool _sessionEnded = false;

  bool _hasLocationPermissionCached = false;
  Position? _lastKnownPosition;
  DateTime? _lastPositionTimestamp;
  final int _positionCacheSeconds = 5;
  bool _deniedForeverNotified = false;

  @override
  void initState() {
    super.initState();
    _initCameraAndModel();
  }

  void _stopMonitoring() {
    _endSession();
  }

  Future<void> _endSession() async {
    if (_sessionEnded) return;
    _sessionEnded = true;

    _periodicTimer?.cancel();
    _sessionTimer?.cancel();
    _uiUpdateTimer?.cancel();

    if (!mounted) return;

    final hazards = ref.read(sessionPotholesProvider).length;
    final durationMinutes = _sessionStart == null
        ? 0
        : DateTime.now().difference(_sessionStart!).inMinutes;

    double km = 0.0;
    try {
      if (_sessionStartPosition != null) {
        try {
          _sessionEndPosition = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.high,
          );
        } catch (_) {}
      }

      if (_sessionStartPosition != null && _sessionEndPosition != null) {
        final distance = Distance();
        final meters = distance.as(
          LengthUnit.Meter,
          LatLng(
            _sessionStartPosition!.latitude,
            _sessionStartPosition!.longitude,
          ),
          LatLng(_sessionEndPosition!.latitude, _sessionEndPosition!.longitude),
        );
        km = meters / 1000.0;
      } else if (_sessionDetections.length > 1) {
        final distance = Distance();
        double meters = 0.0;
        for (var i = 1; i < _sessionDetections.length; i++) {
          final prev = _sessionDetections[i - 1];
          final cur = _sessionDetections[i];
          meters += distance.as(
            LengthUnit.Meter,
            LatLng(prev.latitude, prev.longitude),
            LatLng(cur.latitude, cur.longitude),
          );
        }
        km = meters / 1000.0;
      }
    } catch (_) {}

    try {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => SessionCompleteScreen(
            detections: ref.read(sessionPotholesProvider),
            hazards: hazards,
            durationMinutes: durationMinutes,
            kilometers: km,
          ),
        ),
      );
    } catch (_) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Monitoring stopped')));
      Navigator.of(context).pop();
    }
  }

  Future<void> _initCameraAndModel() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;

      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _controller = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
      );

      _initializeFuture = _controller!.initialize();
      await _initializeFuture;

      await _loadModel();

      if (_modelLoaded) {
        _sessionStart = DateTime.now();
        _hazardsCount = 0;
        _sessionDetections.clear();

        try {
          final existing = ref.read(sessionPotholesProvider);
          if (existing.isNotEmpty) {
            ref.read(potholeProvider.notifier).addFromMaps(existing);
          }
          ref.read(sessionPotholesProvider.notifier).clear();
        } catch (_) {}

        if (await _ensureLocationPermission()) {
          try {
            _sessionStartPosition = await _getCachedOrFreshPosition();
          } catch (_) {}
        }

        _captureAndRun();
        _periodicTimer = Timer.periodic(
          const Duration(seconds: 5),
          (_) => _captureAndRun(),
        );
        _uiUpdateTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted) setState(() {});
        });

        if (widget.sessionDuration != null) {
          _sessionTimer = Timer(widget.sessionDuration!, _endSession);
        }
      }

      if (mounted) setState(() {});
    } catch (_) {
      _modelLoaded = false;
    }
  }

  Future<bool> _ensureLocationPermission() async {
    try {
      if (_hasLocationPermissionCached) return true;

      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return false;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied) return false;

      if (permission == LocationPermission.deniedForever) {
        if (!_deniedForeverNotified && mounted) {
          _deniedForeverNotified = true;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Location permission permanently denied. Enable it in settings.',
              ),
              duration: Duration(seconds: 6),
            ),
          );
        }
        return false;
      }

      _hasLocationPermissionCached = true;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<Position?> _getCachedOrFreshPosition() async {
    try {
      if (_lastKnownPosition != null && _lastPositionTimestamp != null) {
        final age = DateTime.now()
            .difference(_lastPositionTimestamp!)
            .inSeconds;
        if (age <= _positionCacheSeconds) return _lastKnownPosition;
      }

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      _lastKnownPosition = pos;
      _lastPositionTimestamp = DateTime.now();
      return pos;
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset(
        'assets/model/best_float32.tflite',
      );
      _interpreter!.allocateTensors();

      final inputTensor = _interpreter!.getInputTensor(0);
      const int fixedSize = 640;
      final int channels = inputTensor.shape.length >= 4
          ? inputTensor.shape[3]
          : (inputTensor.shape.isNotEmpty ? inputTensor.shape.last : 3);

      _inputShape = [1, fixedSize, fixedSize, channels];
      _inputType = inputTensor.type;

      final rawLabels = await rootBundle.loadString('assets/model/labels.txt');
      _labels = rawLabels
          .split('\n')
          .where((s) => s.trim().isNotEmpty)
          .toList();

      _modelLoaded = true;
    } catch (_) {
      _modelLoaded = false;
    }
  }

  Future<void> _saveDetection(Map<String, dynamic> entry) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/detections.json');
      List existing = [];
      if (await file.exists()) {
        final contents = await file.readAsString();
        if (contents.trim().isNotEmpty) {
          existing = json.decode(contents) as List;
        }
      }
      existing.add(entry);
      await file.writeAsString(json.encode(existing));
    } catch (_) {}
  }

  @override
  void dispose() {
    _periodicTimer?.cancel();
    _sessionTimer?.cancel();
    _uiUpdateTimer?.cancel();
    _interpreter?.close();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _captureAndRun() async {
    if (!mounted) return;
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (!_modelLoaded || _interpreter == null) return;
    if (_isProcessing) return;
    if (_controller!.value.isTakingPicture) return;

    _isProcessing = true;

    try {
      final XFile file = await _controller!.takePicture();
      final bytes = await file.readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null) return;

      final int inH = _inputShape[1];
      final int inW = _inputShape[2];
      final int inC = _inputShape[3];

      final resized = img.copyResize(image, width: inW, height: inH);

      dynamic input;
      if (_inputType == TensorType.uint8 || _inputType == TensorType.int8) {
        input = List.generate(
          1,
          (_) => List.generate(
            inH,
            (_) => List.generate(inW, (_) => List.filled(inC, 0)),
          ),
        );
        for (int y = 0; y < inH; y++) {
          for (int x = 0; x < inW; x++) {
            final p = resized.getPixel(x, y);
            input[0][y][x][0] = img.getRed(p);
            if (inC > 1) input[0][y][x][1] = img.getGreen(p);
            if (inC > 2) input[0][y][x][2] = img.getBlue(p);
          }
        }
      } else {
        input = List.generate(
          1,
          (_) => List.generate(
            inH,
            (_) => List.generate(inW, (_) => List.filled(inC, 0.0)),
          ),
        );
        for (int y = 0; y < inH; y++) {
          for (int x = 0; x < inW; x++) {
            final p = resized.getPixel(x, y);
            input[0][y][x][0] = (img.getRed(p) - 127.5) / 127.5;
            if (inC > 1) input[0][y][x][1] = (img.getGreen(p) - 127.5) / 127.5;
            if (inC > 2) input[0][y][x][2] = (img.getBlue(p) - 127.5) / 127.5;
          }
        }
      }

      final outTensor = _interpreter!.getOutputTensor(0);
      final outShape = outTensor.shape;
      final outType = outTensor.type;

      List<double> flat;
      if (outShape.length == 2 && outShape[0] == 1) {
        final outSize = outShape[1];
        final output = List<double>.filled(outSize, 0.0);
        _interpreter!.run(input, output);
        flat = output;
      } else {
        final outputObj = _makeZeroList(outShape, outType);
        _interpreter!.run(input, outputObj);
        flat = _flattenToDoubleList(outputObj);
      }

      int topIndex = 0;
      double topScore = -double.infinity;
      for (int i = 0; i < flat.length; i++) {
        if (flat[i] > topScore) {
          topScore = flat[i];
          topIndex = i;
        }
      }

      final label = topIndex < _labels.length
          ? _labels[topIndex]
          : 'Label $topIndex';

      if (topScore > _detectionThreshold) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Pothole detected (${topScore.toStringAsFixed(2)})',
              ),
              duration: const Duration(seconds: 2),
            ),
          );
        }

        final hasPermission = await _ensureLocationPermission();
        if (hasPermission) {
          final pos = await _getCachedOrFreshPosition();
          if (pos == null) return;

          String titleFromOsm = '';
          try {
            final place = await _reverseGeocode(pos.latitude, pos.longitude);
            if (place != null && place.trim().isNotEmpty) {
              titleFromOsm = place;
            }
          } catch (_) {}

          final detection = PotholeDetection(
            id: DateTime.now().millisecondsSinceEpoch,
            title: titleFromOsm.isNotEmpty ? titleFromOsm : label,
            description:
                'Detected by model (score ${topScore.toStringAsFixed(2)})',
            status: PotholeStatus.pending,
            latitude: pos.latitude,
            longitude: pos.longitude,
            createdAt: DateTime.now().toIso8601String(),
          );

          setState(() {
            _sessionDetections.add(detection);
            _hazardsCount++;
          });

          try {
            ref.read(sessionPotholesProvider.notifier).add(detection.toJson());
          } catch (_) {}

          await _saveDetection(detection.toJson());
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$label (${topScore.toStringAsFixed(2)})'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (_) {
    } finally {
      _isProcessing = false;
    }
  }

  Future<String?> _reverseGeocode(double lat, double lon) async {
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=$lat&lon=$lon&accept-language=en',
      );
      final resp = await http
          .get(
            uri,
            headers: {
              'User-Agent': 'pitwatch/1.0 (contact: support@example.com)',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final data = json.decode(resp.body) as Map<String, dynamic>;
        final display = data['display_name'] as String?;
        if (display != null && display.trim().isNotEmpty) return display;

        final address = data['address'] as Map<String, dynamic>?;
        if (address != null) {
          final parts = <String>[];
          if (address['road'] != null) parts.add(address['road']);
          if (address['suburb'] != null) parts.add(address['suburb']);
          if (address['city'] != null) parts.add(address['city']);
          if (address['state'] != null) parts.add(address['state']);
          if (address['country'] != null) parts.add(address['country']);
          if (parts.isNotEmpty) return parts.join(', ');
        }
      }
    } catch (_) {}
    return null;
  }

  dynamic _makeZeroList(List<int> shape, TensorType type) {
    if (shape.isEmpty) return 0.0;
    if (shape.length == 1) {
      final len = shape[0];
      if (type == TensorType.uint8 || type == TensorType.int8) {
        return List<int>.filled(len, 0);
      }
      return List<double>.filled(len, 0.0);
    }
    final first = shape[0];
    final rest = shape.sublist(1);
    return List.generate(first, (_) => _makeZeroList(rest, type));
  }

  List<double> _flattenToDoubleList(dynamic arr) {
    final List<double> out = [];
    if (arr is List) {
      for (final e in arr) {
        out.addAll(_flattenToDoubleList(e));
      }
    } else if (arr is num) {
      out.add(arr.toDouble());
    } else {
      out.add(double.tryParse(arr.toString()) ?? 0.0);
    }
    return out;
  }

  String _formatDuration() {
    if (_sessionStart == null) return '00:00';
    final dur = DateTime.now().difference(_sessionStart!);
    final minutes = dur.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = dur.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = dur.inHours;
    if (hours > 0) return '${hours.toString().padLeft(2, '0')}:$minutes';
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final durationStr = _formatDuration();

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: _initializeFuture == null
                  ? Container(color: Colors.black)
                  : FutureBuilder<void>(
                      future: _initializeFuture,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState == ConnectionState.done &&
                            _controller != null &&
                            _controller!.value.isInitialized) {
                          return CameraPreview(_controller!);
                        }
                        return const Center(child: CircularProgressIndicator());
                      },
                    ),
            ),
            Positioned(
              left: 16.w,
              right: 16.w,
              top: 16.h,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _miniCard(title: 'Hazards', value: _hazardsCount.toString()),
                  _recIndicator(),
                  _miniCard(title: 'Duration', value: durationStr),
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 24.h,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    onTap: _stopMonitoring,
                    child: Container(
                      width: 72.w,
                      height: 72.w,
                      decoration: BoxDecoration(
                        color: Colors.redAccent,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.25),
                            blurRadius: 8.r,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Center(
                        child: Icon(
                          Icons.stop,
                          size: 28.sp,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(height: 12.h),
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: 12.w,
                      vertical: 6.h,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(16.r),
                    ),
                    child: Text(
                      'Monitoring Active',
                      style: TextStyle(color: Colors.white, fontSize: 12.sp),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniCard({required String title, required String value}) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 8.h),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.45),
        borderRadius: BorderRadius.circular(12.r),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 4.r,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Text(
            title,
            style: TextStyle(color: Colors.white70, fontSize: 12.sp),
          ),
          SizedBox(height: 6.h),
          Text(
            value,
            style: TextStyle(
              color: Colors.white,
              fontSize: 16.sp,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _recIndicator() {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.45),
        borderRadius: BorderRadius.circular(12.r),
      ),
      child: Row(
        children: [
          Container(
            width: 8.w,
            height: 8.w,
            decoration: const BoxDecoration(
              color: Colors.red,
              shape: BoxShape.circle,
            ),
          ),
          SizedBox(width: 8.w),
          Text(
            'REC',
            style: TextStyle(color: Colors.white, fontSize: 12.sp),
          ),
        ],
      ),
    );
  }
}
