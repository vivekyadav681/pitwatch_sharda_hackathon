import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:pitwatch/models/pothole.dart';
import 'package:pitwatch/screens/home/main_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pitwatch/providers/pothole_provider.dart';
import 'package:pitwatch/widgets/issue_card.dart';
import 'package:pitwatch/services/report_service.dart';
import 'package:pitwatch/widgets/session/success_button.dart';
import 'package:pitwatch/widgets/session/view_details_button.dart';

class SessionCompleteScreen extends ConsumerStatefulWidget {
  final List<Map<String, dynamic>> detections;
  final int hazards;
  final int durationMinutes;
  final double kilometers;

  const SessionCompleteScreen({
    super.key,
    this.detections = const [],
    this.hazards = 0,
    this.durationMinutes = 0,
    this.kilometers = 0.0,
  });
  @override
  ConsumerState<SessionCompleteScreen> createState() =>
      _SessionCompleteScreenState();
}

class _SessionCompleteScreenState extends ConsumerState<SessionCompleteScreen> {
  bool _uploading = true;
  int _uploaded = 0;
  int _total = 0;
  @override
  void dispose() {
    // Do not automatically migrate session detections here. Upload is
    // triggered on screen entry; successes are migrated when upload
    // finishes. Leave any failed session detections in session storage
    // for later retry.
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startUpload();
    });
  }

  Future<void> _startUpload() async {
    setState(() {
      _uploading = true;
      _uploaded = 0;
      _total = 0;
    });

    final sessionDetections = ref.read(sessionPotholesProvider);
    // prefer session provider, fall back to passed detections
    final raw = sessionDetections.isNotEmpty
        ? sessionDetections
        : widget.detections;

    if (raw.isEmpty) {
      setState(() {
        _uploading = false;
      });
      return;
    }

    // parse into models
    final parsed = raw
        .map((d) {
          try {
            return PotholeDetection.fromJson(Map<String, dynamic>.from(d));
          } catch (_) {
            return null;
          }
        })
        .whereType<PotholeDetection>()
        .toList();

    _total = parsed.length;

    List<Map<String, dynamic>> results = [];
    try {
      results = await ReportService.postReports(parsed);
    } catch (e) {
      debugPrint('ReportService error: $e');
    }

    // migrate successes to global provider; keep failed ones in session provider
    final failedMaps = <Map<String, dynamic>>[];
    final errors = <String>[];
    for (var i = 0; i < results.length; i++) {
      final res = results[i];
      final ok = res['ok'] == true;
      if (ok) {
        try {
          ref.read(potholeProvider.notifier).addDetection(parsed[i]);
        } catch (_) {}
      } else {
        // re-add original map for retry later
        try {
          failedMaps.add(Map<String, dynamic>.from(raw[i]));
        } catch (_) {}
        final msg = (res['message'] != null)
            ? res['message'].toString()
            : 'Unknown error (status: ${res['status']})';
        errors.add('Item ${i + 1}: $msg');
      }
    }

    // replace session provider with failed maps (if any)
    ref.read(sessionPotholesProvider.notifier).clear();
    for (final m in failedMaps) {
      ref.read(sessionPotholesProvider.notifier).add(m);
    }

    setState(() {
      _uploaded = results.where((r) => r['ok'] == true).length;
      _uploading = false;
    });

    // If there were errors, show dialog with messages
    if (errors.isNotEmpty && mounted) {
      final content = errors.join('\n\n');
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Upload errors'),
          content: SingleChildScrollView(child: Text(content)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessionDetections = ref.watch(sessionPotholesProvider);
    final listDetections = sessionDetections.isNotEmpty
        ? sessionDetections
        : widget.detections;
    final hazardsCount = sessionDetections.length;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: [
              /// HEADER + OVERLAPPING CARD
              Stack(
                clipBehavior: Clip.none,
                children: [
                  const SessionCompleteHeader(),

                  /// Route Card (overlapping)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: -200.h,
                    child: Center(
                      child: Builder(
                        builder: (context) {
                          LatLng center;
                          if (listDetections.isNotEmpty) {
                            center = LatLng(
                              (listDetections
                                      .map(
                                        (d) =>
                                            (d['latitude'] as num).toDouble(),
                                      )
                                      .reduce((a, b) => a + b) /
                                  listDetections.length),
                              (listDetections
                                      .map(
                                        (d) =>
                                            (d['longitude'] as num).toDouble(),
                                      )
                                      .reduce((a, b) => a + b) /
                                  listDetections.length),
                            );
                          } else {
                            center = LatLng(19.0760, 72.8777);
                          }
                          return RouteOverviewCard(
                            center: center,
                            detections: listDetections,
                            onViewFullMap: () {},
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),

              /// SPACE AFTER OVERLAP
              SizedBox(height: 240.h),

              /// CONTENT SECTION
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 16.w),
                child: Column(
                  children: [
                    /// STATS
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        HazardsCard(hazards: hazardsCount),
                        DistanceCard(
                          km: double.parse(
                            widget.kilometers.toStringAsFixed(2),
                          ),
                        ),
                        DurationCard(minutes: widget.durationMinutes),
                      ],
                    ),

                    SizedBox(height: 20.h),

                    /// SUCCESS / UPLOAD STATUS BANNER
                    SuccessButton(
                      text: _uploading
                          ? 'Uploading...'
                          : 'Upload Complete (${_uploaded}/$_total)',
                      loading: _uploading,
                      onTap: null,
                    ),

                    SizedBox(height: 16.h),

                    /// VIEW DETAILS BUTTON
                    ViewDetailsButton(onTap: () {}),

                    SizedBox(height: 20.h),

                    /// DETECTIONS LIST
                    if (listDetections.isNotEmpty) ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Detected Potholes',
                          style: GoogleFonts.inter(
                            fontSize: 16.sp,
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF1E293B),
                          ),
                        ),
                      ),
                      SizedBox(height: 12.h),
                      Column(
                        children: listDetections.map((d) {
                          PotholeDetection det;
                          try {
                            det = PotholeDetection.fromJson(
                              Map<String, dynamic>.from(d),
                            );
                          } catch (_) {
                            // fallback: create minimal detection
                            det = PotholeDetection(
                              id: (d['id'] is int)
                                  ? d['id'] as int
                                  : DateTime.now().millisecondsSinceEpoch,
                              title: d['title']?.toString() ?? 'Pothole',
                              description: d['description']?.toString() ?? '',
                              status: PotholeStatus.unknown,
                              latitude: (d['latitude'] is num)
                                  ? (d['latitude'] as num).toDouble()
                                  : 0.0,
                              longitude: (d['longitude'] is num)
                                  ? (d['longitude'] as num).toDouble()
                                  : 0.0,
                              createdAt:
                                  d['created_at']?.toString() ??
                                  DateTime.now().toIso8601String(),
                            );
                          }
                          return Padding(
                            padding: EdgeInsets.only(bottom: 12.h),
                            child: IssueCard(data: det),
                          );
                        }).toList(),
                      ),
                      SizedBox(height: 12.h),
                    ],

                    /// BACK TO HOME (disabled while uploading)
                    AbsorbPointer(
                      absorbing: _uploading,
                      child: GestureDetector(
                        onTap: _uploading
                            ? null
                            : () {
                                Navigator.of(context).pushReplacement(
                                  MaterialPageRoute(
                                    builder: (_) => const MainScreen(),
                                  ),
                                );
                              },
                        child: Text(
                          "Back to Home",
                          style: GoogleFonts.inter(
                            fontSize: 16.sp,
                            fontWeight: FontWeight.w600,
                            height: 24 / 16,
                            color: _uploading
                                ? const Color(0xFF94A3B8)
                                : const Color(0xFF64748B),
                          ),
                        ),
                      ),
                    ),

                    SizedBox(height: 24.h),
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

class RouteOverviewCard extends StatelessWidget {
  final LatLng center;
  final VoidCallback? onViewFullMap;

  const RouteOverviewCard({
    super.key,
    required this.center,
    this.onViewFullMap,
    this.detections = const [],
  });

  final List<Map<String, dynamic>> detections;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 312.w,
      height: 238.h,
      decoration: BoxDecoration(
        color: const Color(0xFFE6ECF3),
        borderRadius: BorderRadius.circular(16.r),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 24.8.r,
            offset: const Offset(0, 4),
            spreadRadius: -5,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16.r),
        child: Column(
          children: [
            /// MAP SECTION
            Expanded(
              child: Stack(
                children: [
                  IgnorePointer(
                    ignoring: true,
                    child: FlutterMap(
                      options: MapOptions(
                        initialCenter: center,
                        initialZoom: 13.0,
                        interactionOptions: const InteractionOptions(
                          flags: InteractiveFlag.none,
                        ),
                      ),
                      children: [
                        TileLayer(
                          urlTemplate:
                              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
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
                                width: 24.w,
                                height: 24.w,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.redAccent,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 2,
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                      ],
                    ),
                  ),

                  /// Decorative markers (like in image)
                  Positioned(top: 20.h, left: 20.w, child: _dot(Colors.green)),
                  Positioned(
                    top: 40.h,
                    left: 120.w,
                    child: _dot(Colors.lightBlue),
                  ),
                  Positioned(top: 20.h, right: 20.w, child: _dot(Colors.red)),
                ],
              ),
            ),

            /// BOTTOM SECTION
            Container(
              height: 56.h,
              padding: EdgeInsets.symmetric(horizontal: 16.w),
              color: Colors.white,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  /// Left: Route Overview
                  Row(
                    children: [
                      Icon(
                        Icons.send_outlined,
                        size: 16.sp,
                        color: const Color(0xFF64748B),
                      ),
                      SizedBox(width: 6.w),
                      Text(
                        "Route Overview",
                        style: GoogleFonts.inter(
                          fontSize: 14.sp,
                          fontWeight: FontWeight.w400,
                          height: 20 / 14,
                          color: const Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),

                  /// Right: View Full Map
                  GestureDetector(
                    onTap: onViewFullMap,
                    child: Text(
                      "View Full Map",
                      style: GoogleFonts.inter(
                        fontSize: 14.sp,
                        fontWeight: FontWeight.w600,
                        height: 20 / 14,
                        color: const Color(0xFF1E3A8A),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dot(Color color) {
    return Container(
      width: 8.w,
      height: 8.w,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class StatCard extends StatelessWidget {
  final String value;
  final String label;
  final IconData icon;
  final Color iconBorderColor;
  final Color iconBgColor;

  const StatCard({
    super.key,
    required this.value,
    required this.label,
    required this.icon,
    required this.iconBorderColor,
    required this.iconBgColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 90.w,
      height: 160.h,
      padding: EdgeInsets.symmetric(vertical: 16.h),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12.r),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 4.r,
            offset: const Offset(0, 1),
          ),
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 0,
            offset: const Offset(0, -1),
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          /// ICON CIRCLE
          Container(
            width: 36.w,
            height: 36.w,
            decoration: BoxDecoration(
              color: iconBgColor,
              shape: BoxShape.circle,
              border: Border.all(color: iconBorderColor, width: 1.67),
            ),
            child: Icon(icon, size: 18.sp, color: iconBorderColor),
          ),

          SizedBox(height: 10.h),

          /// MAIN VALUE
          Text(
            value,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 24.sp,
              fontWeight: FontWeight.w700,
              height: 32 / 24,
              color: const Color(0xFF1E293B),
            ),
          ),

          SizedBox(height: 4.h),

          /// LABEL
          Text(
            label,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 12.sp,
              fontWeight: FontWeight.w400,
              height: 16 / 12,
              color: const Color(0xFF64748B),
            ),
          ),
        ],
      ),
    );
  }
}

class HazardsCard extends StatelessWidget {
  final int hazards;

  const HazardsCard({super.key, required this.hazards});

  @override
  Widget build(BuildContext context) {
    return StatCard(
      value: hazards.toString(),
      label: "Hazards",
      icon: Icons.warning_amber_rounded,
      iconBorderColor: const Color(0xFFEF4444),
      iconBgColor: const Color(0x1AEF4444),
    );
  }
}

class DistanceCard extends StatelessWidget {
  final double km;

  const DistanceCard({super.key, required this.km});

  @override
  Widget build(BuildContext context) {
    return StatCard(
      value: km.toString(),
      label: "Kilometers",
      icon: Icons.location_on_outlined,
      iconBorderColor: const Color(0xFF1E3A8A),
      iconBgColor: const Color(0x1A1E3A8A),
    );
  }
}

class DurationCard extends StatelessWidget {
  final int minutes;

  const DurationCard({super.key, required this.minutes});

  @override
  Widget build(BuildContext context) {
    return StatCard(
      value: "$minutes\nmin",
      label: "Duration",
      icon: Icons.access_time,
      iconBorderColor: const Color(0xFF22D3EE),
      iconBgColor: const Color(0x1A22D3EE),
    );
  }
}

class SessionCompleteHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final double height;

  const SessionCompleteHeader({
    super.key,
    this.title = "Session Complete!",
    this.subtitle = "Great monitoring work",
    this.height = 260,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: height.h,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment(-0.3, -1),
          end: Alignment(1, 1),
          colors: [Color(0xFF10B981), Color(0xFF10B881)],
          stops: [0.4789, 1],
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          /// ICON STACK (glow + circle + tick)
          Stack(
            alignment: Alignment.center,
            children: [
              /// outer soft glow
              Container(
                width: 80.w,
                height: 80.w,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
              ),

              /// main circle
              Container(
                width: 52.w,
                height: 52.w,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Container(
                    width: 26.w,
                    height: 26.w,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3.33),
                    ),
                    child: Icon(Icons.check, size: 16.sp, color: Colors.white),
                  ),
                ),
              ),
            ],
          ),

          SizedBox(height: 16.h),

          /// MAIN TEXT
          Text(
            title,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 30.sp,
              fontWeight: FontWeight.w700,
              height: 36 / 30,
              color: Colors.white,
            ),
          ),

          SizedBox(height: 6.h),

          /// SUBTEXT
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 16.sp,
              fontWeight: FontWeight.w400,
              height: 24 / 16,
              color: Colors.white.withOpacity(0.8),
            ),
          ),
        ],
      ),
    );
  }
}
