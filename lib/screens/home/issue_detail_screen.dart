import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:pitwatch/models/pothole.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

class IssueDetailScreen extends StatefulWidget {
  final PotholeDetection data;

  const IssueDetailScreen({super.key, required this.data});

  @override
  State<IssueDetailScreen> createState() => _IssueDetailScreenState();
}

class _IssueDetailScreenState extends State<IssueDetailScreen> {
  bool? _tilesAvailable;

  @override
  void initState() {
    super.initState();
    _checkTiles();
  }

  Future<void> _checkTiles() async {
    try {
      final uri = Uri.parse('https://tile.openstreetmap.org/0/0/0.png');
      final resp = await http
          .get(
            uri,
            headers: {
              'User-Agent': 'pitwatch/1.0 (contact: support@example.com)',
            },
          )
          .timeout(const Duration(seconds: 5));

      if (!mounted) return;
      setState(() {
        _tilesAvailable = resp.statusCode == 200;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _tilesAvailable = false;
      });
    }
  }

  String _formatDate(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return iso;
    }
  }

  Widget _statusChip(IssueStatus s) {
    switch (s) {
      case IssueStatus.reported:
        return _chip(
          'Reported',
          const Color(0xFFF0B100),
          const Color(0xFFD08700),
        );
      case IssueStatus.underRepair:
        return _chip(
          'Under Repair',
          const Color(0xFF2B7FFF),
          const Color(0xFF155DFC),
        );
      case IssueStatus.fixed:
        return _chip('Fixed', const Color(0xFF10B981), const Color(0xFF10B981));
    }
  }

  Widget _chip(String label, Color bg, Color textColor) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 6.h),
      decoration: BoxDecoration(
        color: bg.withOpacity(0.12),
        borderRadius: BorderRadius.circular(100.r),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 14.sp,
          fontWeight: FontWeight.w600,
          color: textColor,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final center = LatLng(data.latitude, data.longitude);
    final created = _formatDate(data.createdAt);
    final tilesOk = _tilesAvailable ?? true;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 280.h,
                child: ClipRRect(
                  borderRadius: BorderRadius.only(
                    bottomLeft: Radius.circular(20.r),
                    bottomRight: Radius.circular(20.r),
                  ),
                  child: tilesOk
                      ? FlutterMap(
                          options: MapOptions(
                            initialCenter: center,
                            initialZoom: 16.0,
                          ),
                          children: [
                            TileLayer(
                              urlTemplate:
                                  'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                              userAgentPackageName: 'com.pitwatch.app',
                              tileProvider: NetworkTileProvider(),
                            ),
                            MarkerLayer(
                              markers: [
                                Marker(
                                  point: center,
                                  width: 48.w,
                                  height: 48.w,
                                  child: Icon(
                                    Icons.location_on,
                                    color: Colors.redAccent,
                                    size: 36.sp,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        )
                      : Container(
                          color: Colors.white,
                          child: Center(
                            child: Padding(
                              padding: EdgeInsets.all(16.w),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.map_outlined,
                                    size: 48.sp,
                                    color: const Color(0xFF64748B),
                                  ),
                                  SizedBox(height: 12.h),
                                  Text(
                                    'Map tiles unavailable',
                                    style: GoogleFonts.inter(
                                      fontSize: 16.sp,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  SizedBox(height: 8.h),
                                  Text(
                                    'The map provider may be blocking tile requests from this app.',
                                    style: GoogleFonts.inter(
                                      color: const Color(0xFF64748B),
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                  SizedBox(height: 12.h),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      ElevatedButton(
                                        onPressed: () {
                                          final txt =
                                              '${data.latitude.toStringAsFixed(6)}, ${data.longitude.toStringAsFixed(6)}';
                                          Clipboard.setData(
                                            ClipboardData(text: txt),
                                          );
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text(
                                                'Coordinates copied',
                                              ),
                                            ),
                                          );
                                        },
                                        child: const Text('Copy coordinates'),
                                      ),
                                      SizedBox(width: 8.w),
                                      OutlinedButton(
                                        onPressed: _checkTiles,
                                        child: const Text('Retry'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                ),
              ),
              Padding(
                padding: EdgeInsets.all(16.w),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            data.title,
                            style: GoogleFonts.inter(
                              fontSize: 22.sp,
                              fontWeight: FontWeight.w700,
                              color: const Color(0xFF1E293B),
                            ),
                          ),
                        ),
                        SizedBox(width: 12.w),
                        _statusChip(mapPotholeStatus(data.status)),
                      ],
                    ),
                    SizedBox(height: 12.h),
                    Text(
                      data.description.isNotEmpty
                          ? data.description
                          : 'No description provided',
                      style: GoogleFonts.inter(
                        fontSize: 16.sp,
                        color: const Color(0xFF475569),
                      ),
                    ),
                    SizedBox(height: 18.h),
                    Row(
                      children: [
                        const Icon(
                          Icons.my_location_outlined,
                          color: Color(0xFF64748B),
                        ),
                        SizedBox(width: 8.w),
                        Text(
                          '${data.latitude.toStringAsFixed(6)}, ${data.longitude.toStringAsFixed(6)}',
                          style: GoogleFonts.inter(
                            color: const Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 12.h),
                    Row(
                      children: [
                        const Icon(
                          Icons.calendar_today_outlined,
                          color: Color(0xFF64748B),
                        ),
                        SizedBox(width: 8.w),
                        Text(
                          created,
                          style: GoogleFonts.inter(
                            color: const Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 20.h),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF1E3A8A),
                              padding: EdgeInsets.symmetric(vertical: 14.h),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12.r),
                              ),
                            ),
                            onPressed: () {},
                            child: Text(
                              'Share',
                              style: GoogleFonts.inter(
                                fontSize: 16.sp,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(width: 12.w),
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            padding: EdgeInsets.symmetric(
                              vertical: 14.h,
                              horizontal: 18.w,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12.r),
                            ),
                          ),
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(
                            'Close',
                            style: GoogleFonts.inter(
                              fontSize: 16.sp,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
