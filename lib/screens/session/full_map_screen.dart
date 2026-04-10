import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:google_fonts/google_fonts.dart';

class FullMapScreen extends StatelessWidget {
  final List<Map<String, dynamic>> detections;
  final LatLng? center;

  const FullMapScreen({super.key, this.detections = const [], this.center});

  LatLng _computeCenter() {
    if (center != null) return center!;
    if (detections.isEmpty) return LatLng(19.0760, 72.8777);
    final latSum = detections
        .map((d) => (d['latitude'] as num).toDouble())
        .reduce((a, b) => a + b);
    final lonSum = detections
        .map((d) => (d['longitude'] as num).toDouble())
        .reduce((a, b) => a + b);
    return LatLng(latSum / detections.length, lonSum / detections.length);
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
                final lat = (d['latitude'] as num).toDouble();
                final lon = (d['longitude'] as num).toDouble();
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
