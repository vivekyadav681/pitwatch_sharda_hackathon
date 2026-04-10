import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:pitwatch/screens/auth/signup_page.dart';
import 'package:pitwatch/screens/home/main_screen.dart';
import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pitwatch/services/token_service.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    // request location permission once, then navigate after splash delay
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _maybeRequestLocationPermissionOnce();
      if (!mounted) return;
      Timer(const Duration(seconds: 2), () async {
        if (!mounted) return;
        try {
          final prefs = await SharedPreferences.getInstance();
          // Debug: dump all shared preference entries to console
          try {
            final keys = prefs.getKeys();
            debugPrint('--- SharedPreferences dump start ---');
            for (final k in keys) {
              debugPrint('$k: ${prefs.get(k)}');
            }
            debugPrint('--- SharedPreferences dump end ---');
          } catch (e) {
            debugPrint('Failed to dump SharedPreferences: $e');
          }
          final token = prefs.getString('access_token');
          final refresh = prefs.getString('refresh_token');
          // Start token auto-refresh if a refresh token exists.
          if (refresh != null && refresh.trim().isNotEmpty) {
            TokenService.startAutoRefresh();
          }

          if (token != null && token.trim().isNotEmpty) {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => const MainScreen()),
            );
          } else {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (_) => const SignupPage()),
            );
          }
        } catch (e) {
          // fallback to signup on any error
          if (!mounted) return;
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const SignupPage()),
          );
        }
      });
    });
  }

  Future<void> _maybeRequestLocationPermissionOnce() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final asked = prefs.getBool('asked_location_permission') ?? false;
      if (asked) return;

      // Check current permission
      LocationPermission permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      } else if (permission == LocationPermission.deniedForever) {
        // Can't request programmatically; the user must enable from settings.
        // We still mark as asked to avoid repeated prompts.
      }

      await prefs.setBool('asked_location_permission', true);
    } catch (e) {
      // ignore errors; don't block navigation
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment(-0.96, -0.27), // approx 168.33deg
            end: Alignment(0.94, 0.33),
            colors: [Color(0xFF172033), Color(0xFF1E356C)],
            stops: [0.0, 1.0],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Logo
                Image.asset(
                  'assets/images/logo.png',
                  width: 92.w,
                  height: 92.w,
                  fit: BoxFit.contain,
                ),
                SizedBox(height: 24.h),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
