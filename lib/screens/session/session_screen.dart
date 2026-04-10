import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:image/image.dart' as img;
import 'package:pitwatch/models/pothole.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'dart:io';
import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:latlong2/latlong.dart';
import 'sessionCompleteScreen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pitwatch/providers/pothole_provider.dart';

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
  DateTime? _sessionStart;
  Position? _sessionStartPosition;
  Position? _sessionEndPosition;
  Timer? _uiUpdateTimer;

  Interpreter? _interpreter;
  late List<int> _inputShape;
  late TensorType _inputType;
  List<String> _labels = [];
  bool _modelLoaded = false;
  bool _isProcessing = false;
  List<PotholeDetection> _sessionDetections = [];
  static const double _detectionThreshold = 0.9; // reasonable default
  static const double _nmsIouThreshold = 0.45;
  int _hazardsCount = 0;

  @override
  void initState() {
    super.initState();
    _initCameraAndModel();
  }

  void _stopMonitoring() {
    _endSession();
  }

  Future<void> _endSession() async {
    _periodicTimer?.cancel();
    _sessionTimer?.cancel();
    _uiUpdateTimer?.cancel();
    debugPrint('Session ended');
    if (!mounted) return;

    // compute summary stats
    final hazards = ref.read(sessionPotholesProvider).length;
    final durationMinutes = _sessionStart == null
        ? 0
        : DateTime.now().difference(_sessionStart!).inMinutes;

    double km = 0.0;
    try {
      // if we captured a start position, attempt to capture an end position now
      if (_sessionStartPosition != null) {
        try {
          _sessionEndPosition = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.high,
          );
        } catch (e) {
          debugPrint('Failed to get end position: $e');
        }
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
    } catch (e) {
      debugPrint('Error computing km: $e');
      km = 0.0;
    }

    // navigate to SessionCompleteScreen and pass detections + stats
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
    } catch (e) {
      debugPrint('Navigation to session complete failed: $e');
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

      // start periodic capture only if model loaded
      if (_modelLoaded) {
        debugPrint(
          'Model loaded — starting capture immediately and periodic timer',
        );
        // mark session start
        _sessionStart = DateTime.now();
        // reset session counters
        _hazardsCount = 0;
        _sessionDetections.clear();
        // Before clearing session-level Riverpod storage, move any existing
        // session detections into the global pothole provider so totals
        // remain accurate.
        try {
          final existing = ref.read(sessionPotholesProvider);
          if (existing.isNotEmpty) {
            ref.read(potholeProvider.notifier).addFromMaps(existing);
          }
          ref.read(sessionPotholesProvider.notifier).clear();
        } catch (e) {
          debugPrint('Failed to migrate/clear session potholes provider: $e');
        }
        // capture session start location if available
        if (await _ensureLocationPermission()) {
          try {
            _sessionStartPosition = await Geolocator.getCurrentPosition(
              desiredAccuracy: LocationAccuracy.high,
            );
            debugPrint(
              'Session start location: ${_sessionStartPosition!.latitude}, ${_sessionStartPosition!.longitude}',
            );
          } catch (e) {
            debugPrint('Failed to capture session start location: $e');
          }
        }

        // run one immediate capture then schedule periodic captures
        _captureAndRun();
        _periodicTimer = Timer.periodic(
          const Duration(seconds: 5),
          (_) => _captureAndRun(),
        );
        // UI timer to refresh duration/hazards
        _uiUpdateTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted) setState(() {});
        });
        // if a session duration was provided, schedule session end
        if (widget.sessionDuration != null) {
          _sessionTimer = Timer(widget.sessionDuration!, () {
            debugPrint('Session duration elapsed; ending session');
            _endSession();
          });
        }
      }
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Model load error: $e');
      _modelLoaded = false;
    }
  }

  Future<bool> _ensureLocationPermission() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return false;
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) return false;
      }
      if (permission == LocationPermission.deniedForever) return false;
      return true;
    } catch (e) {
      debugPrint('Location permission check error: $e');
      return false;
    }
  }

  Future<void> _loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset(
        'assets/model/best_float32.tflite',
      );
      _interpreter!.allocateTensors();
      final inputTensor = _interpreter!.getInputTensor(0);
      // Enforce new model input size of 640x640 while preserving channel count
      const int fixedSize = 640;
      final int channels = (inputTensor.shape.length >= 4)
          ? inputTensor.shape[3]
          : (inputTensor.shape.isNotEmpty ? inputTensor.shape.last : 3);
      _inputShape = [
        1,
        fixedSize,
        fixedSize,
        channels,
      ]; // [1, height, width, channels]
      _inputType = inputTensor.type;

      final rawLabels = await rootBundle.loadString('assets/model/labels.txt');
      _labels = rawLabels
          .split('\n')
          .where((s) => s.trim().isNotEmpty)
          .toList();

      _modelLoaded = true;
      debugPrint(
        'Model loaded: enforcedInput=$_inputShape (channels=$channels) type=$_inputType labels=${_labels.length}',
      );
    } catch (e) {
      debugPrint('Model load error: $e');
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
      debugPrint('Saved detection: $entry');
    } catch (e) {
      debugPrint('Failed to save detection: $e');
    }
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

      // build input according to tensor type
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

      // If output is a single classification vector [1, N], use a flat double buffer.
      // For YOLO-like models the output is commonly [1, N, D] where D>=6.
      List<double> flat;
      dynamic outputObj;
      List<Map<String, dynamic>> yoloDetections = [];

      if (outShape.length == 2 && outShape[0] == 1) {
        final outSize = outShape[1];
        final output = List<double>.filled(outSize, 0.0);
        _interpreter!.run(input, output);
        flat = output;
      } else {
        // Create nested buffer matching the shape and run inference into it.
        outputObj = _makeZeroList(outShape, outType);
        _interpreter!.run(input, outputObj);

        // If output looks like YOLO ([1, N, D] with D >= 6) parse it.
        if (outShape.length == 3 && outShape[0] == 1 && outShape[2] >= 6) {
          try {
            yoloDetections = _parseYoloOutput(outputObj, inW, inH);
          } catch (e) {
            debugPrint('YOLO parse error: $e');
          }
        }

        // fallback to flatten for classification-like outputs
        flat = _flattenToDoubleList(outputObj);
      }

      // If YOLO detections were produced, handle them (multiple per frame)
      if (yoloDetections.isNotEmpty) {
        final detectionMsg = 'Potholes detected (${yoloDetections.length})';
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(detectionMsg),
              duration: const Duration(seconds: 2),
            ),
          );
        }

        final hasPermission = await _ensureLocationPermission();
        if (hasPermission) {
          try {
            final pos = await Geolocator.getCurrentPosition(
              desiredAccuracy: LocationAccuracy.high,
            );

            // Attempt reverse-geocoding via OpenStreetMap Nominatim
            String titleFromOsm = '';
            try {
              final place = await _reverseGeocode(pos.latitude, pos.longitude);
              if (place != null && place.trim().isNotEmpty) {
                titleFromOsm = place;
              }
            } catch (e) {
              debugPrint('Reverse geocode error: $e');
            }

            // For each YOLO detection, create a PotholeDetection using current GPS
            int created = 0;
            for (final det in yoloDetections) {
              if (created >= 6) break; // limit per-frame creations
              final score = det['score'] as double;
              final labelIdx = det['class'] as int;
              final lab = (labelIdx < _labels.length)
                  ? _labels[labelIdx]
                  : 'pothole';

              final detection = PotholeDetection(
                id: DateTime.now().millisecondsSinceEpoch + created,
                title: titleFromOsm.isNotEmpty ? titleFromOsm : lab,
                description:
                    'Detected by YOLOv8 (score ${score.toStringAsFixed(2)})',
                status: PotholeStatus.pending,
                latitude: pos.latitude,
                longitude: pos.longitude,
                createdAt: DateTime.now().toIso8601String(),
              );

              // store in-session list and update UI (increment hazards)
              setState(() {
                _sessionDetections.add(detection);
                _hazardsCount++;
              });

              // update Riverpod session provider (store full detection for upload)
              try {
                ref
                    .read(sessionPotholesProvider.notifier)
                    .add(detection.toJson());
              } catch (e) {
                debugPrint('Failed to add detection to session provider: $e');
              }

              // persist immediately as well
              await _saveDetection(detection.toJson());

              created++;
            }

            debugPrint(
              'YOLO detections created: $created at ${pos.latitude}, ${pos.longitude}',
            );
          } catch (e) {
            debugPrint('Failed to get location: $e');
          }
        } else {
          debugPrint('Location permission not granted; detection not saved');
        }
      } else {
        // classification fallback: find top index
        int topIndex = 0;
        double topScore = -double.infinity;
        for (int i = 0; i < flat.length; i++) {
          final val = flat[i];
          if (val > topScore) {
            topScore = val;
            topIndex = i;
          }
        }

        final label = (topIndex < _labels.length)
            ? _labels[topIndex]
            : 'Label $topIndex';
        if (topScore > _detectionThreshold) {
          final detectionMsg =
              'Pothole detected (${topScore.toStringAsFixed(2)})';
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(detectionMsg),
                duration: const Duration(seconds: 2),
              ),
            );
          }

          final hasPermission = await _ensureLocationPermission();
          if (hasPermission) {
            try {
              final pos = await Geolocator.getCurrentPosition(
                desiredAccuracy: LocationAccuracy.high,
              );
              String titleFromOsm = '';
              try {
                final place = await _reverseGeocode(
                  pos.latitude,
                  pos.longitude,
                );
                if (place != null && place.trim().isNotEmpty)
                  titleFromOsm = place;
              } catch (e) {}

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
                ref
                    .read(sessionPotholesProvider.notifier)
                    .add(detection.toJson());
              } catch (_) {}
              await _saveDetection(detection.toJson());
            } catch (e) {
              debugPrint('Failed to get location: $e');
            }
          }
        } else {
          final msg = '$label (${topScore.toStringAsFixed(2)})';
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(msg),
                duration: const Duration(seconds: 2),
              ),
            );
          }
        }
      }
    } catch (e, st) {
      debugPrint('capture/inference error: $e');
      debugPrint(st.toString());
    } finally {
      _isProcessing = false;
    }
  }

  // Reverse geocode using OpenStreetMap Nominatim (simple, no-auth)
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
    } catch (e) {
      debugPrint('Reverse geocode failed: $e');
    }
    return null;
  }

  // Helper: create nested zero-filled list matching `shape` and `type`.
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

  // Helper: flatten nested list into List<double>
  List<double> _flattenToDoubleList(dynamic arr) {
    final List<double> out = [];
    if (arr is List) {
      for (final e in arr) {
        out.addAll(_flattenToDoubleList(e));
      }
    } else if (arr is num) {
      out.add(arr.toDouble());
    } else {
      final v = double.tryParse(arr.toString());
      out.add(v ?? 0.0);
    }
    return out;
  }

  /// Parse YOLO-like model output in the shape [1, N, D] where D >= 6
  /// Expected row format: [cx, cy, w, h, conf, ...class_scores]
  List<Map<String, dynamic>> _parseYoloOutput(
    dynamic outputObj,
    int inW,
    int inH,
  ) {
    final results = <Map<String, dynamic>>[];
    try {
      if (outputObj is List && outputObj.isNotEmpty) {
        final outer = outputObj[0];
        if (outer is List) {
          for (final row in outer) {
            if (row is List) {
              final r = row
                  .map(
                    (e) => (e is num)
                        ? e.toDouble()
                        : double.tryParse(e.toString()) ?? 0.0,
                  )
                  .toList();
              if (r.length < 6) continue;
              final cx = r[0];
              final cy = r[1];
              final w = r[2];
              final h = r[3];
              final conf = r[4];
              final classScores = r.sublist(5);
              if (classScores.isEmpty) continue;
              // find best class
              int best = 0;
              double bestCls = -double.infinity;
              for (int i = 0; i < classScores.length; i++) {
                final v = (classScores[i] is num)
                    ? (classScores[i] as num).toDouble()
                    : double.tryParse(classScores[i].toString()) ?? 0.0;
                if (v > bestCls) {
                  bestCls = v;
                  best = i;
                }
              }
              final score = conf * bestCls;
              if (score < _detectionThreshold) continue;

              // Convert box to pixel coordinates. If coords appear normalized (<=1), scale by inW/inH
              double x1, y1, x2, y2;
              if (cx <= 1.01 && cy <= 1.01 && w <= 1.01 && h <= 1.01) {
                final px = cx * inW;
                final py = cy * inH;
                final pw = w * inW;
                final ph = h * inH;
                x1 = px - pw / 2;
                y1 = py - ph / 2;
                x2 = px + pw / 2;
                y2 = py + ph / 2;
              } else {
                x1 = cx - w / 2;
                y1 = cy - h / 2;
                x2 = cx + w / 2;
                y2 = cy + h / 2;
              }

              results.add({
                'class': best,
                'score': score,
                'box': [x1, y1, x2, y2],
              });
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Error parsing YOLO output: $e');
    }

    // Apply NMS
    final kept = _nms(results, _nmsIouThreshold);
    return kept;
  }

  List<Map<String, dynamic>> _nms(
    List<Map<String, dynamic>> dets,
    double iouThresh,
  ) {
    if (dets.isEmpty) return [];
    final byScore = List<Map<String, dynamic>>.from(dets);
    byScore.sort(
      (a, b) => (b['score'] as double).compareTo(a['score'] as double),
    );
    final kept = <Map<String, dynamic>>[];
    for (final d in byScore) {
      final box = d['box'] as List<dynamic>;
      bool skip = false;
      for (final k in kept) {
        final ob = k['box'] as List<dynamic>;
        final iou = _iou(box.cast<double>(), ob.cast<double>());
        if (iou > iouThresh) {
          skip = true;
          break;
        }
      }
      if (!skip) kept.add(d);
    }
    return kept;
  }

  double _iou(List<double> a, List<double> b) {
    final x1 = a[0].clamp(double.negativeInfinity, double.infinity);
    final y1 = a[1].clamp(double.negativeInfinity, double.infinity);
    final x2 = a[2].clamp(double.negativeInfinity, double.infinity);
    final y2 = a[3].clamp(double.negativeInfinity, double.infinity);
    final x1b = b[0];
    final y1b = b[1];
    final x2b = b[2];
    final y2b = b[3];

    final interLeft = x1 > x1b ? x1 : x1b;
    final interTop = y1 > y1b ? y1 : y1b;
    final interRight = x2 < x2b ? x2 : x2b;
    final interBottom = y2 < y2b ? y2 : y2b;
    final interW = (interRight - interLeft).clamp(0.0, double.infinity);
    final interH = (interBottom - interTop).clamp(0.0, double.infinity);
    final interArea = interW * interH;

    final areaA =
        (x2 - x1).clamp(0.0, double.infinity) *
        (y2 - y1).clamp(0.0, double.infinity);
    final areaB =
        (x2b - x1b).clamp(0.0, double.infinity) *
        (y2b - y1b).clamp(0.0, double.infinity);
    final union = areaA + areaB - interArea;
    if (union <= 0) return 0.0;
    return interArea / union;
  }

  String _formatDuration() {
    if (_sessionStart == null) return '00:00';
    final dur = DateTime.now().difference(_sessionStart!);
    final minutes = dur.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = dur.inSeconds.remainder(60).toString().padLeft(2, '0');
    final hours = dur.inHours;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:$minutes';
    }
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final hazardsCount = _hazardsCount;
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

            // top stats
            Positioned(
              left: 16.w,
              right: 16.w,
              top: 16.h,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _miniCard(title: 'Hazards', value: hazardsCount.toString()),
                  _recIndicator(),
                  _miniCard(title: 'Duration', value: durationStr),
                ],
              ),
            ),

            // bottom stop button + monitoring chip
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
        crossAxisAlignment: CrossAxisAlignment.center,
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
            decoration: BoxDecoration(
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
