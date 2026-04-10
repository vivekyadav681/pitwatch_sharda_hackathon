import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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
          if (jsonBody.containsKey('access')) {
            await prefs.setString(
              'access_token',
              jsonBody['access'].toString(),
            );
          }
          if (jsonBody.containsKey('refresh')) {
            await prefs.setString(
              'refresh_token',
              jsonBody['refresh'].toString(),
            );
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
      } catch (_) {}
      return {'success': false, 'message': 'Network error: $e'};
    }
  }
}
