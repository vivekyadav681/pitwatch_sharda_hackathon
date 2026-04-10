import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:pitwatch/screens/session/inference_worker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:pitwatch/models/pothole.dart';
import 'package:pitwatch/providers/pothole_provider.dart';
import 'package:pitwatch/screens/session/sessionCompleteScreen.dart';

class SessionScreen extends ConsumerStatefulWidget {
  final Duration? sessionDuration;
  const SessionScreen({Key? key, this.sessionDuration}) : super(key: key);

  @override
  ConsumerState<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends ConsumerState<SessionScreen> {
  CameraController? _controller;
  Future<void>? _initializeFuture;
  bool _modelLoaded = false;
  Interpreter? _interpreter;
  DateTime? _sessionStart;
  int _hazardsCount = 0;
  List<PotholeDetection> _sessionDetections = [];
  Position? _sessionStartPosition;
  Timer? _periodicTimer;
  Timer? _uiUpdateTimer;
  Timer? _sessionTimer;
  bool _hasLocationPermissionCached = false;
  bool _deniedForeverNotified = false;
  Position? _lastKnownPosition;
  DateTime? _lastPositionTimestamp;
  final int _positionCacheSeconds = 15;
  List<int> _inputShape = [1, 640, 640, 3];
  TensorType? _inputType;
  List<String> _labels = [];
  double _detectionThreshold = 0.9;
  bool _isProcessing = false;
  final List<String> _pendingFiles = [];
  final List<Future> _processingTasks = [];
  InferenceWorker? _inferenceWorker;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initCameraAndModel();
    });
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

        _captureAndQueue();
        _periodicTimer = Timer.periodic(
          const Duration(seconds: 5),
          (_) => _captureAndQueue(),
        );
        _uiUpdateTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted) setState(() {});
        });

        if (widget.sessionDuration != null) {
          _sessionTimer = Timer(widget.sessionDuration!, _endSession);
        }
      }

      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('init camera/model error: $e');
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
        'assets/model/best_float32(1).tflite',
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

      // Start inference worker isolate with model bytes for off-main-thread inference.
      try {
        final bd = await rootBundle.load('assets/model/best_float32.tflite');
        final modelBytes = bd.buffer.asUint8List();
        _inferenceWorker = InferenceWorker();
        await _inferenceWorker!.start(
          modelBytes,
          _inputShape,
          _inputType?.index ?? TensorType.float32.index,
        );
      } catch (e) {
        debugPrint('inference worker start failed: $e');
        _inferenceWorker = null;
      }
    } catch (e) {
      debugPrint('model load error: $e');
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
    _inferenceWorker?.stop();
    super.dispose();
  }

  /// Capture one image and queue it for background processing.
  Future<void> _captureAndQueue() async {
    if (!mounted) return;
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (!_modelLoaded || _interpreter == null) return;
    if (_controller!.value.isTakingPicture) return;

    try {
      final XFile file = await _controller!.takePicture();

      // immediately persist path and increment hazard count for responsive UX
      _pendingFiles.add(file.path);
      setState(() {
        _hazardsCount++;
      });

      final task = _processImageFile(file.path).whenComplete(() {
        _pendingFiles.remove(file.path);
      });

      _processingTasks.add(task);

      task.whenComplete(() {
        _processingTasks.remove(task);
      });
    } catch (e) {
      debugPrint('capture error: $e');
    }
  }

  Future<void> _processImageFile(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return;

      double score = 0.0;
      String label = 'unknown';

      if (_inferenceWorker != null && _inferenceWorker!.isRunning) {
        try {
          final res = await _inferenceWorker!.runInference(path);
          if (res.containsKey('error')) {
            debugPrint('worker error: ${res['error']}');
          }
          score = (res['score'] as num?)?.toDouble() ?? 0.0;
          final li = res['labelIndex'] as int? ?? -1;
          label = (li >= 0 && li < _labels.length)
              ? _labels[li]
              : (res['label'] as String? ?? 'unknown');
        } catch (e) {
          debugPrint('worker inference failed, falling back: $e');
          final fb = await _inferOnMainThread(path);
          score = fb['score'] as double;
          label = fb['label'] as String;
        }
      } else {
        final fb = await _inferOnMainThread(path);
        score = fb['score'] as double;
        label = fb['label'] as String;
      }

      // Show model output in realtime as a SnackBar for quick feedback.
      if (mounted) {
        try {
          final pct = (score * 100).toStringAsFixed(0);
          final message = '${label} (${pct}%)';
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(message),
              duration: const Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
        } catch (e) {
          debugPrint('show snackbar error: $e');
        }
      }

      await _handleDetectionIfNeeded(score, label);
    } catch (e) {
      debugPrint('process image error: $e');
    } finally {
      // delete the file after processing to free space
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  Future<Map<String, Object>> _inferOnMainThread(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return {'score': 0.0, 'label': 'unknown'};
      final bytes = await f.readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null) return {'score': 0.0, 'label': 'unknown'};

      double score = 0.0;
      String label = 'unknown';

      if (_interpreter != null && _inputType != null) {
        final resized = img.copyResize(
          image,
          width: _inputShape[2],
          height: _inputShape[1],
        );
        final inH = _inputShape[1];
        final inW = _inputShape[2];
        final inC = _inputShape[3];

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
              if (inC > 1)
                input[0][y][x][1] = (img.getGreen(p) - 127.5) / 127.5;
              if (inC > 2) input[0][y][x][2] = (img.getBlue(p) - 127.5) / 127.5;
            }
          }
        }

        try {
          final outTensor = _interpreter!.getOutputTensor(0);
          final outShape = outTensor.shape;
          List<double> flat;
          if (outShape.length == 2 && outShape[0] == 1) {
            final outSize = outShape[1];
            final output = List<double>.filled(outSize, 0.0);
            _interpreter!.run(input, output);
            flat = output;
          } else {
            final outputObj = _makeZeroList(outShape, outTensor.type);
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
          score = topScore;
          label = topIndex < _labels.length
              ? _labels[topIndex]
              : 'label_$topIndex';
        } catch (e) {
          debugPrint('model run error: $e');
        }
      } else {
        int dark = 0;
        for (int y = 0; y < image.height; y += 10) {
          for (int x = 0; x < image.width; x += 10) {
            final p = image.getPixel(x, y);
            final avg = (img.getRed(p) + img.getGreen(p) + img.getBlue(p)) / 3;
            if (avg < 100) dark++;
          }
        }
        score = (dark > 10) ? 0.95 : 0.2;
        label = 'pothole';
      }

      return {'score': score, 'label': label};
    } catch (e) {
      debugPrint('infer main thread error: $e');
      return {'score': 0.0, 'label': 'unknown'};
    }
  }

  Future<void> _handleDetectionIfNeeded(double score, String label) async {
    if (score > _detectionThreshold) {
      final hasPermission = await _ensureLocationPermission();
      if (!hasPermission) return;
      final pos = await _getCachedOrFreshPosition();
      if (pos == null) return;

      String titleFromOsm = '';
      try {
        final place = await _reverseGeocode(pos.latitude, pos.longitude);
        if (place != null && place.trim().isNotEmpty) titleFromOsm = place;
      } catch (_) {}

      final detection = PotholeDetection(
        id: DateTime.now().millisecondsSinceEpoch,
        title: titleFromOsm.isNotEmpty ? titleFromOsm : label,
        description: 'Detected by model (score ${score.toStringAsFixed(2)})',
        status: PotholeStatus.pending,
        latitude: pos.latitude,
        longitude: pos.longitude,
        createdAt: DateTime.now().toIso8601String(),
      );

      setState(() {
        _sessionDetections.add(detection);
      });

      try {
        ref.read(sessionPotholesProvider.notifier).add(detection.toJson());
      } catch (_) {}

      await _saveDetection(detection.toJson());
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

  void _endSession() {
    // ensure we only end once
    if (!mounted) return;
    // wait for processing tasks to finish, then navigate
    if (_processingTasks.isNotEmpty) {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const Center(child: CircularProgressIndicator()),
      );
      Future.wait(_processingTasks).whenComplete(() {
        if (mounted) Navigator.of(context).pop();
        _navigateToComplete();
      });
    } else {
      _navigateToComplete();
    }
  }

  void _navigateToComplete() {
    try {
      final hazards = _hazardsCount;
      final durationMinutes = _sessionStart == null
          ? 0
          : DateTime.now().difference(_sessionStart!).inMinutes;
      double km = 0.0;
      try {
        // best-effort compute kilometers if we have positions
        if (_sessionStartPosition != null && _lastKnownPosition != null) {
          final prev = _sessionStartPosition!;
          final cur = _lastKnownPosition!;
          final meters = Distance().as(
            LengthUnit.Meter,
            LatLng(prev.latitude, prev.longitude),
            LatLng(cur.latitude, cur.longitude),
          );
          km = meters / 1000.0;
        }
      } catch (_) {}

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
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Monitoring stopped')));
      Navigator.of(context).pop();
    }
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
                    onTap: _endSession,
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
