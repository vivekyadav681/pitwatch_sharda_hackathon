import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';

class DrowsinessAlertWidget extends StatefulWidget {
  final VoidCallback? onAwake;
  final bool autoPlay;

  const DrowsinessAlertWidget({Key? key, this.onAwake, this.autoPlay = true})
    : super(key: key);

  @override
  State<DrowsinessAlertWidget> createState() => _DrowsinessAlertWidgetState();
}

class _DrowsinessAlertWidgetState extends State<DrowsinessAlertWidget> {
  final AudioPlayer _player = AudioPlayer();

  @override
  void initState() {
    super.initState();
    if (widget.autoPlay) playAlarm();
  }

  Future<void> playAlarm() async {
    try {
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.play(AssetSource('audio/alarm.mp3'));
    } catch (e) {
      debugPrint('playAlarm error: $e');
    }
  }

  Future<void> stopAlarm() async {
    try {
      await _player.stop();
    } catch (e) {
      debugPrint('stopAlarm error: $e');
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  void _onAwakePressed() async {
    await stopAlarm();
    widget.onAwake?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.redAccent.withOpacity(0.98),
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.warning_rounded, color: Colors.white, size: 100),
              const SizedBox(height: 20),
              const Text(
                "WAKE UP!",
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                "Eyes closed for too long",
                style: TextStyle(color: Colors.white70, fontSize: 16),
              ),
              const SizedBox(height: 40),
              SizedBox(
                width: 200,
                height: 52,
                child: ElevatedButton(
                  onPressed: _onAwakePressed,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.redAccent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text(
                    "I'm Awake",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
