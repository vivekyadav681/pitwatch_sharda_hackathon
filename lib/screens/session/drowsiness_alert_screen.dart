import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';

class DrowsinessAlertScreen extends StatefulWidget {
  const DrowsinessAlertScreen({super.key});

  @override
  State<DrowsinessAlertScreen> createState() =>
      _DrowsinessAlertScreenState();
}

class _DrowsinessAlertScreenState
    extends State<DrowsinessAlertScreen> {

  final AudioPlayer _player = AudioPlayer();

  @override
  void initState() {
    super.initState();
    playAlarm();
  }

  Future<void> playAlarm() async {
    await _player.setReleaseMode(ReleaseMode.loop);
    await _player.play(AssetSource('audio/alarm.mp3'));
  }

  Future<void> stopAlarm() async {
    await _player.stop();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  void onAwakePressed() async {
    await stopAlarm();
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.redAccent,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.warning_rounded,
                color: Colors.white,
                size: 100,
              ),
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
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 40),
              SizedBox(
                width: 200,
                height: 52,
                child: ElevatedButton(
                  onPressed: onAwakePressed,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.redAccent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text(
                    "I'm Awake",
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }
}