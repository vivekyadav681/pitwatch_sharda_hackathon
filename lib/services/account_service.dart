import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pitwatch/services/token_service.dart';

class AccountService {
  static const String _signupUrl =
      'https://pitwatch.onrender.com/api/v1/accounts/signup/';

  /// Attempts to create a new account. Returns a map with keys:
  /// - `success`: bool
  /// - `message`: String (error or success message)
  /// - `data`: parsed JSON when success
  static Future<Map<String, dynamic>> signup({
    required String username,
    required String email,
    required String password,
    required String firstName,
    required String lastName,
  }) async {
    try {
      final uri = Uri.parse(_signupUrl);
      final body = json.encode({
        'username': username,
        'email': email,
        'password': password,
        'first_name': firstName,
        'last_name': lastName,
      });
      final resp = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'User-Agent': 'pitwatch/1.0',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 15));

      final status = resp.statusCode;
      if (status >= 200 && status < 300) {
        final jsonBody = json.decode(resp.body);
        return {
          'success': true,
          'message': 'Account created',
          'data': jsonBody,
        };
      }

      // try to decode error message
      try {
        final err = json.decode(resp.body);
        if (err is Map && err['detail'] != null) {
          return {'success': false, 'message': err['detail'].toString()};
        }
        // some APIs return field errors
        if (err is Map) {
          final msgs = <String>[];
          err.forEach((k, v) {
            msgs.add('$k: ${v.toString()}');
          });
          return {'success': false, 'message': msgs.join(' | ')};
        }
      } catch (_) {}

      return {'success': false, 'message': 'Signup failed (status $status)'};
    } catch (e) {
      return {'success': false, 'message': 'Network error: $e'};
    }
  }

  static const String _loginUrl =
      'https://pitwatch.onrender.com/api/v1/accounts/login/';

  /// Attempt to log in. On success stores `access` and `refresh` tokens in
  /// SharedPreferences under keys `access_token` and `refresh_token`.
  /// Returns a map with `success`, `message`, and optional `data`.
  static Future<Map<String, dynamic>> login({
    required String username,
    required String password,
  }) async {
    try {
      final uri = Uri.parse(_loginUrl);
      final body = json.encode({'username': username, 'password': password});
      final resp = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'User-Agent': 'pitwatch/1.0',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 15));

      final status = resp.statusCode;
      if (status >= 200 && status < 300) {
        final jsonBody = json.decode(resp.body) as Map<String, dynamic>;
        try {
          final prefs = await SharedPreferences.getInstance();

          // normalize access token from multiple possible API shapes
          String? accessVal;
          if (jsonBody.containsKey('access'))
            accessVal = jsonBody['access']?.toString();
          accessVal ??= jsonBody['access_token']?.toString();
          accessVal ??= jsonBody['token']?.toString();
          if (accessVal == null && jsonBody.containsKey('data')) {
            final d = jsonBody['data'];
            if (d is Map && d.containsKey('access'))
              accessVal = d['access']?.toString();
            accessVal ??= d is Map ? d['access_token']?.toString() : null;
          }

          // some APIs nest tokens under `user` (e.g., {detail:..., user:{access:..., refresh:...}})
          if (accessVal == null && jsonBody.containsKey('user')) {
            final u = jsonBody['user'];
            if (u is Map && u.containsKey('access'))
              accessVal = u['access']?.toString();
            accessVal ??= u is Map ? u['access_token']?.toString() : null;
            accessVal ??= u is Map ? u['token']?.toString() : null;
          }

          String? refreshVal;
          if (jsonBody.containsKey('refresh'))
            refreshVal = jsonBody['refresh']?.toString();
          refreshVal ??= jsonBody['refresh_token']?.toString();

          if (refreshVal == null && jsonBody.containsKey('user')) {
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

          // also store raw JSON for later if needed
          await prefs.setString('auth_payload', resp.body);
        } catch (e) {
          // non-fatal: token storage failed
        }

        return {
          'success': true,
          'message': 'Login successful',
          'data': jsonBody,
        };
      }

      // try to decode error message
      try {
        final err = json.decode(resp.body);
        if (err is Map && err['detail'] != null) {
          return {'success': false, 'message': err['detail'].toString()};
        }
        if (err is Map) {
          final msgs = <String>[];
          err.forEach((k, v) {
            msgs.add('$k: ${v.toString()}');
          });
          return {'success': false, 'message': msgs.join(' | ')};
        }
      } catch (_) {}

      if (status == 400 || status == 401) {
        return {'success': false, 'message': 'Invalid credentials'};
      }

      return {'success': false, 'message': 'Login failed (status $status)'};
    } catch (e) {
      return {'success': false, 'message': 'Network error: $e'};
    }
  }

  static const String _logoutUrl =
      'https://pitwatch.onrender.com/api/v1/accounts/admin/logout/';

  static const String _meUrl =
      'https://pitwatch.onrender.com/api/v1/accounts/me/';

  /// Log out by posting the refresh token to the server, then clearing
  /// stored credentials from SharedPreferences. Returns a map with
  /// `success` and `message`.
  static Future<Map<String, dynamic>> logout() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final refresh = prefs.getString('refresh_token');
      final access = prefs.getString('access_token');

      if (refresh == null || refresh.trim().isEmpty) {
        // No refresh token; just clear stored credentials
        await prefs.remove('access_token');
        await prefs.remove('refresh_token');
        await prefs.remove('auth_payload');
        await prefs.remove('user_profile');
        return {'success': true, 'message': 'Logged out locally'};
      }

      final uri = Uri.parse(_logoutUrl);
      final body = json.encode({'refresh_token': refresh});
      final headers = {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'User-Agent': 'pitwatch/1.0',
      };
      if (access != null && access.trim().isNotEmpty) {
        headers['Authorization'] = 'Bearer ${access.trim()}';
      }

      final resp = await http
          .post(uri, headers: headers, body: body)
          .timeout(const Duration(seconds: 10));

      // Regardless of server response, remove local tokens to log out.
      await prefs.remove('access_token');
      await prefs.remove('refresh_token');
      await prefs.remove('auth_payload');
      await prefs.remove('user_profile');

      // Stop token auto-refresh if running.
      try {
        await TokenService.stopAutoRefresh();
      } catch (_) {}

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return {'success': true, 'message': 'Logged out'};
      }

      // try to decode error
      try {
        final decoded = json.decode(resp.body);
        return {
          'success': false,
          'message': decoded is Map && decoded['detail'] != null
              ? decoded['detail'].toString()
              : 'Logout failed (status ${resp.statusCode})',
        };
      } catch (_) {
        return {
          'success': false,
          'message': 'Logout failed (status ${resp.statusCode})',
        };
      }
    } catch (e) {
      // On network error, still clear local tokens
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('access_token');
        await prefs.remove('refresh_token');
        await prefs.remove('auth_payload');
        await prefs.remove('user_profile');
      } catch (_) {}
      return {'success': false, 'message': 'Network error: $e'};
    }
  }

  /// Fetches the current user's profile from the API using the stored
  /// access token and persists it to SharedPreferences under `user_profile`.
  /// Returns a map with `success`, optional `data` and `message`.
  static Future<Map<String, dynamic>> fetchProfile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final access = prefs.getString('access_token');
      if (access == null || access.trim().isEmpty) {
        return {'success': false, 'message': 'No access token available'};
      }

      final uri = Uri.parse(_meUrl);
      final headers = {
        'Accept': 'application/json',
        'User-Agent': 'pitwatch/1.0',
        'Authorization': 'Bearer ${access.trim()}',
      };

      final resp = await http
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 10));

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final jsonBody = json.decode(resp.body);
        // persist raw JSON so other parts of app can read cached profile
        try {
          await prefs.setString('user_profile', resp.body);
        } catch (_) {}
        return {'success': true, 'data': jsonBody};
      }

      try {
        final decoded = json.decode(resp.body);
        final msg = decoded is Map && decoded['detail'] != null
            ? decoded['detail'].toString()
            : 'Failed to fetch profile (status ${resp.statusCode})';
        return {'success': false, 'message': msg, 'status': resp.statusCode};
      } catch (_) {
        return {
          'success': false,
          'message': 'Failed to fetch profile (status ${resp.statusCode})',
        };
      }
    } catch (e) {
      return {'success': false, 'message': 'Network error: $e'};
    }
  }
}
