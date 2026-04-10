import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:pitwatch/models/pothole.dart';

class ReportService {
  // Endpoint for creating reports
  static const String _base = 'https://pitwatch.onrender.com/api/v1/reports/';

  static const String _nominatim =
      'https://nominatim.openstreetmap.org/reverse?format=jsonv2';

  /// Post a single `PotholeDetection` to the backend.
  /// Returns true when server responds with 2xx.
  static Future<bool> postReport(PotholeDetection detection) async {
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

      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (e) {
      // network or parse error
      return false;
    }
  }

  /// Post multiple detections in sequence. Returns list of booleans
  /// indicating success for each item in the same order.
  static Future<List<bool>> postReports(List<PotholeDetection> list) async {
    final results = <bool>[];
    for (final d in list) {
      final ok = await postReport(d);
      results.add(ok);
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
