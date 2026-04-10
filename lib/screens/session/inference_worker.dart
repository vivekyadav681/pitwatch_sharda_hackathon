import 'dart:async';
import 'dart:isolate';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

class InferenceWorker {
  Isolate? _isolate;
  late SendPort _toIsolate;
  final ReceivePort _fromIsolate = ReceivePort();
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  int _msgId = 0;
  bool _running = false;

  bool get isRunning => _running;

  Future<void> start(
    Uint8List modelBytes,
    List<int> inputShape,
    int inputTypeIndex,
  ) async {
    final completer = Completer<void>();

    _fromIsolate.listen((message) {
      if (message is SendPort) {
        _toIsolate = message;
        _running = true;
        if (!completer.isCompleted) completer.complete();
      } else if (message is Map) {
        final int id = message['id'] as int;
        final Map<String, dynamic> result = Map<String, dynamic>.from(
          message['result'] as Map,
        );
        final c = _pending.remove(id);
        c?.complete(result);
      }
    });

    final entry = <String, dynamic>{
      'sendPort': _fromIsolate.sendPort,
      'modelBytes': modelBytes,
      'inputShape': inputShape,
      'inputTypeIndex': inputTypeIndex,
    };

    _isolate = await Isolate.spawn(_isolateEntry, entry);
    return completer.future;
  }

  Future<Map<String, dynamic>> runInference(String filePath) {
    if (!_running) return Future.error('Inference worker not running');
    final id = ++_msgId;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    _toIsolate.send({'id': id, 'path': filePath});
    return c.future;
  }

  void stop() {
    try {
      if (_running) {
        _toIsolate.send({'cmd': 'stop'});
      }
    } catch (_) {}
    try {
      _fromIsolate.close();
    } catch (_) {}
    try {
      _isolate?.kill(priority: Isolate.immediate);
    } catch (_) {}
    _running = false;
  }

  static void _isolateEntry(Map initial) async {
    final SendPort mainPort = initial['sendPort'] as SendPort;
    final Uint8List modelBytes = initial['modelBytes'] as Uint8List;
    final List<int> inputShape = (initial['inputShape'] as List).cast<int>();
    final int inputTypeIndex = initial['inputTypeIndex'] as int;

    final rp = ReceivePort();
    mainPort.send(rp.sendPort);

    Interpreter? interpreter;
    try {
      interpreter = Interpreter.fromBuffer(modelBytes);
      interpreter.allocateTensors();
    } catch (e) {
      // If interpreter fails to initialize, we'll still listen for stop command and reply with errors.
      mainPort.send({
        'id': -1,
        'result': {'error': 'interpreter_init_failed: $e'},
      });
    }

    await for (final msg in rp) {
      try {
        if (msg is Map && msg['cmd'] == 'stop') {
          interpreter?.close();
          break;
        }

        if (msg is Map && msg['id'] != null && msg['path'] != null) {
          final int id = msg['id'] as int;
          final String path = msg['path'] as String;

          Map<String, dynamic> result = {'score': 0.0, 'labelIndex': -1};

          try {
            final bytes = File(path).readAsBytesSync();
            final image = img.decodeImage(bytes);
            if (image == null) {
              mainPort.send({'id': id, 'result': result});
              continue;
            }

            final resized = img.copyResize(
              image,
              width: inputShape[2],
              height: inputShape[1],
            );

            final inH = inputShape[1];
            final inW = inputShape[2];
            final inC = inputShape[3];

            dynamic input;
            // TensorType enum indices: use index mapping
            if (inputTypeIndex == TensorType.uint8.index ||
                inputTypeIndex == TensorType.int8.index) {
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
                  if (inC > 2)
                    input[0][y][x][2] = (img.getBlue(p) - 127.5) / 127.5;
                }
              }
            }

            if (interpreter == null) {
              mainPort.send({
                'id': id,
                'result': {'error': 'interpreter_null'},
              });
              continue;
            }

            final outTensor = interpreter.getOutputTensor(0);
            final outShape = outTensor.shape;
            final outputObj = _makeZeroList(outShape, outTensor.type);
            interpreter.run(input, outputObj);
            final flat = _flattenToDoubleList(outputObj);

            int topIndex = 0;
            double topScore = -double.infinity;
            for (int i = 0; i < flat.length; i++) {
              if (flat[i] > topScore) {
                topScore = flat[i];
                topIndex = i;
              }
            }

            result['score'] = topScore;
            result['labelIndex'] = topIndex;
          } catch (e) {
            result = {'error': e.toString(), 'score': 0.0, 'labelIndex': -1};
          }

          mainPort.send({'id': id, 'result': result});
        }
      } catch (e) {
        // ignore per-item errors
      }
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
}
