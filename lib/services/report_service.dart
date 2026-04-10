import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pitwatch/models/pothole.dart';

class ReportService {
  // Endpoint for creating reports
  static const String _base = 'https://pitwatch.onrender.com/api/v1/reports/';

  static const String _nominatim =
      'https://nominatim.openstreetmap.org/reverse?format=jsonv2';

  /// Post a single `PotholeDetection` to the backend.
  /// Returns true when server responds with 2xx.
  static Future<Map<String, dynamic>> postReport(
    PotholeDetection detection,
  ) async {
    // Build title with best-effort reverse geocoding.
    String title = detection.title;
    try {
      final rev = await _reverseGeocode(
        detection.latitude,
        detection.longitude,
      );
      if (rev != null && rev.isNotEmpty) title = rev;
    } catch (e) {
      // ignore reverse geocode failures but capture for debugging if needed
    }

    final uri = Uri.parse(_base);
    final bodyMap = {
      'title': title,
      'description': detection.description,
      'latitude': detection.latitude,
      'longitude': detection.longitude,
    };
    final body = json.encode(bodyMap);

    // Include access token from SharedPreferences if available
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('access_token');
      final headers = {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'User-Agent': 'pitwatch/1.0',
      };
      if (token != null && token.trim().isNotEmpty) {
        final t = token.trim();
        headers['Authorization'] = 'Bearer $t';
        headers['token'] = t;
      }

      http.Response resp;
      try {
        resp = await http
            .post(uri, headers: headers, body: body)
            .timeout(const Duration(seconds: 15));
      } on TimeoutException catch (e) {
        return {
          'ok': false,
          'status': null,
          'error': 'timeout',
          'message': 'Request timed out: ${e.message ?? e.toString()}',
        };
      } on SocketException catch (e) {
        return {
          'ok': false,
          'status': null,
          'error': 'network',
          'message': 'Network error: ${e.message}',
        };
      } on HandshakeException catch (e) {
        return {
          'ok': false,
          'status': null,
          'error': 'tls',
          'message': 'TLS handshake failed: ${e.message}',
        };
      } on http.ClientException catch (e) {
        return {
          'ok': false,
          'status': null,
          'error': 'client',
          'message': 'HTTP client error: ${e.message}',
        };
      }

      final status = resp.statusCode;
      if (status >= 200 && status < 300) {
        return {'ok': true, 'status': status, 'message': resp.body};
      }

      // Try to decode server error message
      try {
        final decoded = jsonDecode(resp.body);
        if (decoded is Map && decoded['detail'] != null) {
          return {
            'ok': false,
            'status': status,
            'error': 'server',
            'message': decoded['detail'].toString(),
          };
        }
        if (decoded is Map) {
          return {
            'ok': false,
            'status': status,
            'error': 'server',
            'message': decoded.toString(),
          };
        }
      } on FormatException catch (e) {
        return {
          'ok': false,
          'status': status,
          'error': 'parse',
          'message': 'Invalid JSON from server: ${e.message}',
        };
      } catch (e) {
        return {
          'ok': false,
          'status': status,
          'error': 'server',
          'message': resp.body,
        };
      }
    } on Exception catch (e) {
      return {
        'ok': false,
        'status': null,
        'error': 'unknown',
        'message': e.toString(),
      };
    }
    // Fallback - should not be reached, but satisfies non-nullable return.
    return {
      'ok': false,
      'status': null,
      'error': 'unknown',
      'message': 'Unexpected end of postReport',
    };
  }

  /// Post multiple detections in sequence. Returns list of booleans
  /// indicating success for each item in the same order.
  static Future<List<Map<String, dynamic>>> postReports(
    List<PotholeDetection> list,
  ) async {
    final results = <Map<String, dynamic>>[];
    for (final d in list) {
      try {
        final res = await postReport(d);
        results.add(res);
      } catch (e) {
        results.add({
          'ok': false,
          'status': null,
          'error': 'unknown',
          'message': e.toString(),
        });
      }
    }
    return results;
  }

  /// Fetch paginated reports for the current user.
  /// Returns a map with `ok` bool and `data` when successful. Example `data`
  /// matches the API shape: `{count, page, page_size, results: [...]}`
  static Future<Map<String, dynamic>> fetchReports({
    int page = 1,
    int pageSize = 10,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('access_token');

      final uri = Uri.parse('$_base?page=$page&page_size=$pageSize');
      final headers = {
        'Accept': 'application/json',
        'User-Agent': 'pitwatch/1.0',
      };
      if (token != null && token.trim().isNotEmpty) {
        final t = token.trim();
        headers['Authorization'] = 'Bearer $t';
        headers['token'] = t;
      }

      http.Response resp;
      try {
        resp = await http
            .get(uri, headers: headers)
            .timeout(const Duration(seconds: 12));
      } on TimeoutException catch (e) {
        return {
          'ok': false,
          'status': null,
          'error': 'timeout',
          'message': 'Request timed out: ${e.message ?? e.toString()}',
        };
      } on SocketException catch (e) {
        return {
          'ok': false,
          'status': null,
          'error': 'network',
          'message': 'Network error: ${e.message}',
        };
      } on HandshakeException catch (e) {
        return {
          'ok': false,
          'status': null,
          'error': 'tls',
          'message': 'TLS handshake failed: ${e.message}',
        };
      } on http.ClientException catch (e) {
        return {
          'ok': false,
          'status': null,
          'error': 'client',
          'message': 'HTTP client error: ${e.message}',
        };
      }

      final status = resp.statusCode;
      if (status >= 200 && status < 300) {
        try {
          final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
          return {'ok': true, 'data': decoded};
        } on FormatException catch (e) {
          return {
            'ok': false,
            'status': status,
            'error': 'parse',
            'message': 'Invalid JSON from server: ${e.message}',
          };
        }
      }

      try {
        final decoded = jsonDecode(resp.body);
        return {
          'ok': false,
          'status': status,
          'error': 'server',
          'message': decoded is Map && decoded['detail'] != null
              ? decoded['detail'].toString()
              : decoded.toString(),
        };
      } on FormatException catch (e) {
        return {
          'ok': false,
          'status': status,
          'error': 'parse',
          'message': 'Invalid JSON from server: ${e.message}',
        };
      }
    } on Exception catch (e) {
      return {
        'ok': false,
        'status': null,
        'error': 'unknown',
        'message': e.toString(),
      };
    }
  }

  /// Fetch counts summary for the current user.
  /// Expected response shape: {"rejected":1,"pending":1,"resolved":1}
  static Future<Map<String, dynamic>> fetchCounts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('access_token');

      final uri = Uri.parse('$_base' + 'counts/');
      final headers = {
        'Accept': 'application/json',
        'User-Agent': 'pitwatch/1.0',
      };
      if (token != null && token.trim().isNotEmpty) {
        final t = token.trim();
        headers['Authorization'] = 'Bearer $t';
        headers['token'] = t;
      }

      http.Response resp;
      try {
        resp = await http
            .get(uri, headers: headers)
            .timeout(const Duration(seconds: 10));
      } on TimeoutException catch (e) {
        return {
          'ok': false,
          'status': null,
          'error': 'timeout',
          'message': 'Request timed out: ${e.message ?? e.toString()}',
        };
      } on SocketException catch (e) {
        return {
          'ok': false,
          'status': null,
          'error': 'network',
          'message': 'Network error: ${e.message}',
        };
      } on HandshakeException catch (e) {
        return {
          'ok': false,
          'status': null,
          'error': 'tls',
          'message': 'TLS handshake failed: ${e.message}',
        };
      } on http.ClientException catch (e) {
        return {
          'ok': false,
          'status': null,
          'error': 'client',
          'message': 'HTTP client error: ${e.message}',
        };
      }

      final status = resp.statusCode;
      if (status >= 200 && status < 300) {
        try {
          final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
          return {'ok': true, 'counts': decoded};
        } on FormatException catch (e) {
          return {
            'ok': false,
            'status': status,
            'error': 'parse',
            'message': 'Invalid JSON from server: ${e.message}',
          };
        }
      }

      try {
        final decoded = jsonDecode(resp.body);
        return {
          'ok': false,
          'status': status,
          'error': 'server',
          'message': decoded is Map && decoded['detail'] != null
              ? decoded['detail'].toString()
              : decoded.toString(),
        };
      } on FormatException catch (e) {
        return {
          'ok': false,
          'status': status,
          'error': 'parse',
          'message': 'Invalid JSON from server: ${e.message}',
        };
      }
    } on Exception catch (e) {
      return {
        'ok': false,
        'status': null,
        'error': 'unknown',
        'message': e.toString(),
      };
    }
  }

  static Future<String?> _reverseGeocode(double lat, double lon) async {
    try {
      final uri = Uri.parse('$_nominatim&lat=$lat&lon=$lon');
      http.Response resp;
      try {
        resp = await http
            .get(
              uri,
              headers: {'User-Agent': 'pitwatch/1.0 (contact@pitwatch.local)'},
            )
            .timeout(const Duration(seconds: 10));
      } on TimeoutException {
        return null;
      } on SocketException {
        return null;
      } on HandshakeException {
        return null;
      }

      if (resp.statusCode == 200) {
        try {
          final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
          final display = decoded['display_name'] as String?;
          return display;
        } catch (_) {
          return null;
        }
      }
    } catch (_) {}
    return null;
  }
}
