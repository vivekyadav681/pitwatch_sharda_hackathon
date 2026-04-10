import 'dart:convert';
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
    try {
      // Attempt to reverse-geocode coordinates to produce a user-friendly
      // title. Nominatim requires a User-Agent header.
      String title = detection.title;
      try {
        final rev = await _reverseGeocode(
          detection.latitude,
          detection.longitude,
        );
        if (rev != null && rev.isNotEmpty) title = rev;
      } catch (_) {}

      final uri = Uri.parse(_base);
      final bodyMap = {
        'title': title,
        'description': detection.description,
        'latitude': detection.latitude,
        'longitude': detection.longitude,
      };
      final body = json.encode(bodyMap);

      // Include access token from SharedPreferences if available
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('access_token');
      final headers = {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'User-Agent': 'pitwatch/1.0',
      };
      if (token != null && token.trim().isNotEmpty) {
        headers['Authorization'] = 'Bearer ${token.trim()}';
      }

      final resp = await http
          .post(uri, headers: headers, body: body)
          .timeout(const Duration(seconds: 15));

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
            'message': decoded['detail'].toString(),
          };
        }
        if (decoded is Map) {
          return {'ok': false, 'status': status, 'message': decoded.toString()};
        }
      } catch (_) {}

      return {'ok': false, 'status': status, 'message': resp.body};
    } catch (e) {
      // network or parse error
      return {'ok': false, 'status': null, 'message': e.toString()};
    }
  }

  /// Post multiple detections in sequence. Returns list of booleans
  /// indicating success for each item in the same order.
  static Future<List<Map<String, dynamic>>> postReports(
    List<PotholeDetection> list,
  ) async {
    final results = <Map<String, dynamic>>[];
    for (final d in list) {
      final res = await postReport(d);
      results.add(res);
    }
    return results;
  }

  static Future<String?> _reverseGeocode(double lat, double lon) async {
    try {
      final uri = Uri.parse('$_nominatim&lat=$lat&lon=$lon');
      final resp = await http
          .get(
            uri,
            headers: {'User-Agent': 'pitwatch/1.0 (contact@pitwatch.local)'},
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
        final display = decoded['display_name'] as String?;
        return display;
      }
    } catch (_) {}
    return null;
  }
}
