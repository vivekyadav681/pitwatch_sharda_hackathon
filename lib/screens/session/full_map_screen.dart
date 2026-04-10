import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:google_fonts/google_fonts.dart';

class FullMapScreen extends StatelessWidget {
  /// `detections` may be a list of `Map<String,dynamic>` or
  /// `PotholeDetection` objects. We accept `List<dynamic>` and
  /// normalize when building markers.
  final List<dynamic> detections;
  final LatLng? center;

  const FullMapScreen({super.key, this.detections = const [], this.center});

  LatLng _computeCenter() {
    if (center != null) return center!;
    if (detections.isEmpty) return LatLng(19.0760, 72.8777);
    double latSum = 0.0;
    double lonSum = 0.0;
    int count = 0;
    for (final d in detections) {
      try {
        if (d is Map) {
          latSum += (d['latitude'] as num).toDouble();
          lonSum += (d['longitude'] as num).toDouble();
        } else {
          // assume object with properties
          final lat = (d.latitude is num)
              ? (d.latitude as num).toDouble()
              : 0.0;
          final lon = (d.longitude is num)
              ? (d.longitude as num).toDouble()
              : 0.0;
          latSum += lat;
          lonSum += lon;
        }
        count++;
      } catch (_) {}
    }
    if (count == 0) return LatLng(19.0760, 72.8777);
    return LatLng(latSum / count, lonSum / count);
  }

  @override
  Widget build(BuildContext context) {
    final mapCenter = _computeCenter();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E3A8A),
        title: Text('Detected Potholes', style: GoogleFonts.inter()),
      ),
      body: FlutterMap(
        options: MapOptions(initialCenter: mapCenter, initialZoom: 13.0),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.pitwatch.app',
            tileProvider: NetworkTileProvider(),
          ),
          if (detections.isNotEmpty)
            MarkerLayer(
              markers: detections.map((d) {
                double lat = 0.0;
                double lon = 0.0;
                try {
                  if (d is Map) {
                    lat = (d['latitude'] as num).toDouble();
                    lon = (d['longitude'] as num).toDouble();
                  } else {
                    lat = (d.latitude as num).toDouble();
                    lon = (d.longitude as num).toDouble();
                  }
                } catch (_) {}

                return Marker(
                  point: LatLng(lat, lon),
                  width: 40.w,
                  height: 40.w,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.redAccent,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }
}
