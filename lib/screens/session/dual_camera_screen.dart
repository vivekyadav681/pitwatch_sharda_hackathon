import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:pitwatch/screens/session/inference_worker.dart';
import 'package:pitwatch/screens/session/drowsiness_alert_widget.dart';

class DualCameraScreen extends ConsumerStatefulWidget {
  const DualCameraScreen({Key? key}) : super(key: key);

  @override
  ConsumerState<DualCameraScreen> createState() => _DualCameraScreenState();
}

class _DualCameraScreenState extends ConsumerState<DualCameraScreen>
    with WidgetsBindingObserver {
  CameraController? _frontController;
  CameraController? _backController;

  CameraDescription? _frontCamera;
  CameraDescription? _backCamera;

  Timer? _backCameraTimer;
  Timer? _frontSampleTimer;

  bool _eyesAreOpen = true;
  bool _showDrowsinessAlert = false;

  Interpreter? _interpreter;
  InferenceWorker? _inferenceWorker;
  List<String> _labels = [];
  List<int> _inputShape = [1, 640, 640, 3];
  TensorType? _inputType;

  bool _dualCamerasAvailable = false;
  bool _inferenceBusy = false;

  final Duration _backInterval = const Duration(seconds: 5);
  final Duration _frontInterval = const Duration(seconds: 1);
  // consecutive-frame gating for drowsiness detection
  int _drowsyCount = 0;
  final int _drowsyFrameThreshold = 3;
  final Duration _drowsyWindow = const Duration(milliseconds: 2000);
  int _firstDrowsyTimestampMs = 0;
  final double _drowsinessScoreThreshold = 0.65;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _initCamerasAndModel();
    });
  }

  Future<void> _initCamerasAndModel() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;

      CameraDescription? front;
      CameraDescription? back;
      for (final c in cameras) {
        if (c.lensDirection == CameraLensDirection.front) front = c;
        if (c.lensDirection == CameraLensDirection.back) back = c;
      }

      _frontCamera = front ?? cameras.first;
      _backCamera =
          back ??
          cameras.firstWhere(
            (c) => c != _frontCamera,
            orElse: () => cameras.first,
          );

      _frontController = CameraController(
        _frontCamera!,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await _frontController!.initialize();
      try {
        await _frontController!.startImageStream(_onFrontImage);
      } catch (e) {
        debugPrint('startImageStream failed: $e');
      }

      // try creating a persistent back controller but tolerate failures
      try {
        if (_backCamera != null && _backCamera != _frontCamera) {
          _backController = CameraController(
            _backCamera!,
            ResolutionPreset.high,
            enableAudio: false,
          );
          await _backController!.initialize();
          _dualCamerasAvailable = true;
        }
      } catch (e) {
        debugPrint('Back camera persistent init failed: $e');
        try {
          await _backController?.dispose();
        } catch (_) {}
        _backController = null;
        _dualCamerasAvailable = false;
      }

      await _loadModel();
      _startTimers();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('init dual cameras error: $e');
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
      debugPrint('load model failed: $e');
    }
  }

  void _startTimers() {
    _backCameraTimer?.cancel();

    // front sampling will be driven by the image stream callback; keep only
    // the back capture timer here
    _backCameraTimer = Timer.periodic(_backInterval, (_) {
      if (_eyesAreOpen) _captureBackPhoto();
    });
  }

  Future<void> _sampleFront() async {
    // retained for backward compatibility; primary front sampling is handled
    // by the image stream in `_onFrontImage`.
    return;
  }

  int _lastFrontSampleMs = 0;

  void _onFrontImage(CameraImage image) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastFrontSampleMs < _frontInterval.inMilliseconds) return;
    if (_inferenceBusy) return;
    _lastFrontSampleMs = now;
    _inferenceBusy = true;
    try {
      final img.Image converted = _convertCameraImage(image);
      _processFrontImg(converted).whenComplete(() {
        _inferenceBusy = false;
      });
    } catch (e) {
      debugPrint('onFrontImage convert error: $e');
      _inferenceBusy = false;
    }
  }

  img.Image _convertCameraImage(CameraImage image) {
    final int width = image.width;
    final int height = image.height;
    final img.Image imgImage = img.Image(width, height);

    final Plane planeY = image.planes[0];
    final Plane planeU = image.planes[1];
    final Plane planeV = image.planes[2];

    final Uint8List bytesY = planeY.bytes;
    final Uint8List bytesU = planeU.bytes;
    final Uint8List bytesV = planeV.bytes;

    final int strideY = planeY.bytesPerRow;
    final int strideU = planeU.bytesPerRow;
    final int pixelStrideU = planeU.bytesPerPixel ?? 1;

    for (int y = 0; y < height; y++) {
      final int uvRow = (y >> 1) * strideU;
      final int yRow = y * strideY;
      for (int x = 0; x < width; x++) {
        final int uvIndex = uvRow + ((x >> 1) * pixelStrideU);
        final int yIndex = yRow + x;

        final int yp = bytesY[yIndex] & 0xff;
        final int up = bytesU[uvIndex] & 0xff;
        final int vp = bytesV[uvIndex] & 0xff;

        int r = (yp + (1.370705 * (vp - 128))).round();
        int g = (yp - (0.337633 * (up - 128)) - (0.698001 * (vp - 128)))
            .round();
        int b = (yp + (1.732446 * (up - 128))).round();

        r = r.clamp(0, 255);
        g = g.clamp(0, 255);
        b = b.clamp(0, 255);

        imgImage.setPixelRgba(x, y, r, g, b);
      }
    }
    return imgImage;
  }

  Future<void> _processFrontImg(img.Image image) async {
    try {
      // run inference on the provided image
      double score = 0.0;
      String label = 'unknown';

      if (_inferenceWorker != null && _inferenceWorker!.isRunning) {
        // worker expects file paths; fall back to main-thread inference here
        final fb = await _inferFromImg(image);
        score = fb['score'] as double;
        label = fb['label'] as String;
      } else {
        final fb = await _inferFromImg(image);
        score = fb['score'] as double;
        label = fb['label'] as String;
      }

      if (mounted) {
        final pct = (score * 100).toStringAsFixed(0);
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Front: $label (${pct}%)'),
            duration: const Duration(seconds: 1),
          ),
        );
      }

      // use consecutive-frame gating for drowsiness to avoid false positives
      final low = label.toLowerCase();
      final isDrowsy =
          low.contains('drows') ||
          low.contains('sleep') ||
          low.contains('eye') ||
          low.contains('closed');

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (isDrowsy && score > _drowsinessScoreThreshold) {
        if (_firstDrowsyTimestampMs == 0) {
          _firstDrowsyTimestampMs = nowMs;
          _drowsyCount = 0;
        }
        if (nowMs - _firstDrowsyTimestampMs > _drowsyWindow.inMilliseconds) {
          // window expired; start new window
          _firstDrowsyTimestampMs = nowMs;
          _drowsyCount = 1;
        } else {
          _drowsyCount++;
        }

        if (_drowsyCount >= _drowsyFrameThreshold) {
          if (mounted) {
            setState(() {
              _eyesAreOpen = false;
              _showDrowsinessAlert = true;
            });
          }
          // reset gating to avoid repeated triggers
          _drowsyCount = 0;
          _firstDrowsyTimestampMs = 0;
        }
      } else {
        // reset gating on non-drowsy frame
        _drowsyCount = 0;
        _firstDrowsyTimestampMs = 0;
        if (mounted) {
          setState(() {
            _eyesAreOpen = true;
          });
        }
      }
    } catch (e) {
      debugPrint('processFrontImg error: $e');
    }
  }

  Future<Map<String, Object>> _inferFromImg(img.Image image) async {
    try {
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
          dynamic outputObj = _makeZeroList(outShape, outTensor.type);
          _interpreter!.run(input, outputObj);
          final flat = _flattenToDoubleList(outputObj);

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
        label = 'unknown';
      }

      return {'score': score, 'label': label};
    } catch (e) {
      debugPrint('inferFromImg error: $e');
      return {'score': 0.0, 'label': 'unknown'};
    }
  }

  Future<void> _captureBackPhoto() async {
    if (!mounted) return;
    if (_backController == null) {
      // temporary back controller fallback
      if (_backCamera == null) return;
      CameraController? tmp;
      try {
        tmp = CameraController(
          _backCamera!,
          ResolutionPreset.high,
          enableAudio: false,
        );
        await tmp.initialize();
        final photo = await tmp.takePicture();
        await _runPotholeInference(photo.path);
      } catch (e) {
        debugPrint('temporary back capture failed: $e');
      } finally {
        try {
          await tmp?.dispose();
        } catch (_) {}
      }
      return;
    }

    if (!_backController!.value.isInitialized) return;
    if (_backController!.value.isTakingPicture) return;
    try {
      final photo = await _backController!.takePicture();
      await _runPotholeInference(photo.path);
    } catch (e) {
      debugPrint('back capture failed: $e');
    }
  }

  Future<void> _runPotholeInference(String path) async {
    if (!mounted) return;
    try {
      Map<String, dynamic> res = {};
      if (_inferenceWorker != null && _inferenceWorker!.isRunning) {
        res = await _inferenceWorker!.runInference(path);
      } else if (_interpreter != null) {
        final fb = await _inferOnMainThread(path);
        res = {'score': fb['score'], 'label': fb['label']};
      }

      final score = (res['score'] as num?)?.toDouble() ?? 0.0;
      String label = 'unknown';
      if (res.containsKey('labelIndex')) {
        final li = res['labelIndex'] as int? ?? -1;
        label = (li >= 0 && li < _labels.length)
            ? _labels[li]
            : (res['label'] as String? ?? 'unknown');
      } else {
        label = (res['label'] as String?) ?? 'unknown';
      }

      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Back: $label (${(score * 100).toStringAsFixed(0)}%)',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('pothole inference error: $e');
    }
  }

  Future<void> _runDrowsinessInference(String path) async {
    try {
      Map<String, dynamic> res = {};
      if (_inferenceWorker != null && _inferenceWorker!.isRunning) {
        res = await _inferenceWorker!.runInference(path);
      } else if (_interpreter != null) {
        final fb = await _inferOnMainThread(path);
        res = {'score': fb['score'], 'label': fb['label']};
      }

      final score = (res['score'] as num?)?.toDouble() ?? 0.0;
      String label = (res['label'] as String?) ?? 'unknown';
      if (res.containsKey('labelIndex')) {
        final li = res['labelIndex'] as int? ?? -1;
        if (li >= 0 && li < _labels.length) label = _labels[li];
      }

      final low = label.toLowerCase();
      final isDrowsy =
          low.contains('drows') ||
          low.contains('sleep') ||
          low.contains('eye') ||
          low.contains('closed');

      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (isDrowsy && score > _drowsinessScoreThreshold) {
        if (_firstDrowsyTimestampMs == 0) {
          _firstDrowsyTimestampMs = nowMs;
          _drowsyCount = 0;
        }
        if (nowMs - _firstDrowsyTimestampMs > _drowsyWindow.inMilliseconds) {
          _firstDrowsyTimestampMs = nowMs;
          _drowsyCount = 1;
        } else {
          _drowsyCount++;
        }
        if (_drowsyCount >= _drowsyFrameThreshold) {
          if (mounted) {
            setState(() {
              _eyesAreOpen = false;
              _showDrowsinessAlert = true;
            });
          }
          _drowsyCount = 0;
          _firstDrowsyTimestampMs = 0;
        }
      } else {
        // reset gating on non-drowsy frame; don't automatically dismiss alert
        _drowsyCount = 0;
        _firstDrowsyTimestampMs = 0;
        if (mounted) {
          setState(() {
            _eyesAreOpen = true;
          });
        }
      }
    } catch (e) {
      debugPrint('drowsiness inference error: $e');
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
          dynamic outputObj = _makeZeroList(outShape, outTensor.type);
          _interpreter!.run(input, outputObj);
          final flat = _flattenToDoubleList(outputObj);

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
        // fallback heuristic: simple brightness check
        int dark = 0;
        for (int y = 0; y < image.height; y += 10) {
          for (int x = 0; x < image.width; x += 10) {
            final p = image.getPixel(x, y);
            final avg = (img.getRed(p) + img.getGreen(p) + img.getBlue(p)) / 3;
            if (avg < 100) dark++;
          }
        }
        score = (dark > 10) ? 0.95 : 0.2;
        label = 'unknown';
      }

      return {'score': score, 'label': label};
    } catch (e) {
      debugPrint('infer main thread error: $e');
      return {'score': 0.0, 'label': 'unknown'};
    }
  }

  static dynamic _makeZeroList(List<int> shape, TensorType type) {
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

  static List<double> _flattenToDoubleList(dynamic arr) {
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _backCameraTimer?.cancel();
      _frontSampleTimer?.cancel();
      try {
        _frontController?.dispose();
      } catch (_) {}
      try {
        _backController?.dispose();
      } catch (_) {}
      _frontController = null;
      _backController = null;
    } else if (state == AppLifecycleState.resumed) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _initCamerasAndModel(),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _backCameraTimer?.cancel();
    _frontSampleTimer?.cancel();
    try {
      _frontController?.dispose();
    } catch (_) {}
    try {
      _backController?.dispose();
    } catch (_) {}
    _inferenceWorker?.stop();
    _interpreter?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child:
                  (_frontController == null ||
                      !_frontController!.value.isInitialized)
                  ? Container(color: Colors.black)
                  : (_backController != null &&
                        _backController!.value.isInitialized)
                  ? LayoutBuilder(
                      builder: (context, constraints) {
                        if (constraints.maxWidth > constraints.maxHeight) {
                          // landscape: show side-by-side previews
                          return Row(
                            children: [
                              Expanded(child: CameraPreview(_frontController!)),
                              Expanded(child: CameraPreview(_backController!)),
                            ],
                          );
                        }

                        // portrait: stacked with front on top and back preview below
                        return Column(
                          children: [
                            Expanded(child: CameraPreview(_frontController!)),
                            SizedBox(
                              height: constraints.maxHeight * 0.45,
                              child:
                                  _backController != null &&
                                      _backController!.value.isInitialized
                                  ? CameraPreview(_backController!)
                                  : Container(color: Colors.black),
                            ),
                          ],
                        );
                      },
                    )
                  : CameraPreview(_frontController!),
            ),
            Positioned(
              left: 16,
              right: 16,
              top: 16,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'Eyes: ${_eyesAreOpen ? 'Open' : 'Closed'}',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'Back capture: every ${_backInterval.inSeconds}s',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
            if (_showDrowsinessAlert)
              Positioned.fill(
                child: DrowsinessAlertWidget(
                  onAwake: () {
                    if (mounted) {
                      setState(() {
                        _showDrowsinessAlert = false;
                        _eyesAreOpen = true;
                      });
                    }
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
