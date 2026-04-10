import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class TokenService {
  static const String _refreshUrl =
      'https://pitwatch.onrender.com/api/v1/accounts/token/refresh/';

  static Timer? _timer;
  static Duration interval = const Duration(minutes: 25);
  static bool _running = false;

  /// Start automatic periodic refresh. Runs an immediate refresh then
  /// schedules a periodic timer every [every] duration (default 25 minutes).
  static Future<void> startAutoRefresh({Duration? every}) async {
    if (_running) return;
    if (every != null) interval = every;
    _running = true;

    // run immediately, then schedule
    await refreshOnce();
    _timer = Timer.periodic(interval, (_) async {
      await refreshOnce();
    });
    if (kDebugMode)
      debugPrint('TokenService: auto-refresh started (every $interval)');
  }

  /// Stop the automatic refresh timer.
  static Future<void> stopAutoRefresh() async {
    _timer?.cancel();
    _timer = null;
    _running = false;
    if (kDebugMode) debugPrint('TokenService: auto-refresh stopped');
  }

  /// Perform a single refresh attempt using the stored refresh token.
  /// Returns a result map with `ok` bool and additional details.
  static Future<Map<String, dynamic>> refreshOnce() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final refresh = prefs.getString('refresh_token');
      if (refresh == null || refresh.trim().isEmpty) {
        if (kDebugMode) debugPrint('TokenService: no refresh token available');
        return {'ok': false, 'message': 'no_refresh_token'};
      }

      // Use the standard Simple JWT key name `refresh` for compatibility.
      final body = json.encode({'refresh': refresh.trim()});
      final resp = await http
          .post(
            Uri.parse(_refreshUrl),
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'User-Agent': 'pitwatch/1.0',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 12));

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final jsonBody = json.decode(resp.body);

        String? accessVal;
        if (jsonBody is Map && jsonBody.containsKey('access'))
          accessVal = jsonBody['access']?.toString();
        accessVal ??= jsonBody is Map
            ? jsonBody['access_token']?.toString()
            : null;
        accessVal ??= jsonBody is Map ? jsonBody['token']?.toString() : null;
        if (accessVal == null &&
            jsonBody is Map &&
            jsonBody.containsKey('data')) {
          final d = jsonBody['data'];
          if (d is Map && d.containsKey('access'))
            accessVal = d['access']?.toString();
          accessVal ??= d is Map ? d['access_token']?.toString() : null;
        }
        if (accessVal == null &&
            jsonBody is Map &&
            jsonBody.containsKey('user')) {
          final u = jsonBody['user'];
          if (u is Map && u.containsKey('access'))
            accessVal = u['access']?.toString();
          accessVal ??= u is Map ? u['access_token']?.toString() : null;
        }

        String? refreshVal;
        if (jsonBody is Map && jsonBody.containsKey('refresh'))
          refreshVal = jsonBody['refresh']?.toString();
        refreshVal ??= jsonBody is Map
            ? jsonBody['refresh_token']?.toString()
            : null;
        if (refreshVal == null &&
            jsonBody is Map &&
            jsonBody.containsKey('user')) {
          final u = jsonBody['user'];
          if (u is Map && u.containsKey('refresh'))
            refreshVal = u['refresh']?.toString();
          refreshVal ??= u is Map ? u['refresh_token']?.toString() : null;
        }

        if (accessVal != null && accessVal.trim().isNotEmpty) {
          await prefs.setString('access_token', accessVal.trim());
        }
        if (refreshVal != null && refreshVal.trim().isNotEmpty) {
          await prefs.setString('refresh_token', refreshVal.trim());
        }

        // persist raw payload for debugging
        try {
          await prefs.setString('auth_payload', resp.body);
        } catch (_) {}

        if (kDebugMode) debugPrint('TokenService: refresh succeeded');
        return {'ok': true, 'status': resp.statusCode, 'data': jsonBody};
      }

      if (kDebugMode)
        debugPrint('TokenService: refresh failed status ${resp.statusCode}');
      try {
        final decoded = json.decode(resp.body);
        return {'ok': false, 'status': resp.statusCode, 'message': decoded};
      } catch (_) {
        return {'ok': false, 'status': resp.statusCode, 'message': resp.body};
      }
    } catch (e) {
      if (kDebugMode) debugPrint('TokenService: refresh error $e');
      return {'ok': false, 'message': e.toString()};
    }
  }
}
