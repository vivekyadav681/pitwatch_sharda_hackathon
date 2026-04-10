import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:pitwatch/models/pothole.dart';
import 'package:pitwatch/screens/home/issue_detail_screen.dart';

class IssueCard extends StatelessWidget {
  final PotholeDetection data;

  const IssueCard({super.key, required this.data});

  String _timeAgo(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      final y = dt.year.toString().padLeft(4, '0');
      final m = dt.month.toString().padLeft(2, '0');
      final d = dt.day.toString().padLeft(2, '0');
      final hh = dt.hour.toString().padLeft(2, '0');
      final mm = dt.minute.toString().padLeft(2, '0');
      return '$y-$m-$d $hh:$mm';
    } catch (_) {
      return iso;
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => IssueDetailScreen(data: data)),
        );
      },
      child: Container(
        width: 312.w,
        height: 100.h,
        padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16.r),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.25),
              blurRadius: 7.5,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Row(
          children: [
            /// PIN BOX (render small static OpenStreetMap snapshot for location)
            Container(
              width: 70.w,
              height: 70.w,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16.r),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.25),
                    blurRadius: 4,
                    offset: const Offset(0, -1),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12.r),
                child: Builder(
                  builder: (context) {
                    final lat = data.latitude.toString();
                    final lon = data.longitude.toString();
                    // staticmap.openstreetmap.de provides a simple static map image
                    final url =
                        'https://staticmap.openstreetmap.de/staticmap.php?center=$lat,$lon&zoom=15&size=140x140&markers=$lat,$lon,red-pushpin';
                    return Image.network(
                      url,
                      width: 70.w,
                      height: 70.w,
                      fit: BoxFit.cover,
                      errorBuilder: (c, e, s) => Center(
                        child: Image.asset(
                          'assets/icons/pin.png',
                          width: 20.w,
                          height: 20.w,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),

            SizedBox(width: 12.w),

            /// TEXT SECTION
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  /// TITLE + CHIP
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          data.title,
                          style: GoogleFonts.inter(
                            fontSize: 18.sp,
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF1E293B),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      SizedBox(width: 6.w),
                      _buildStatusChip(mapPotholeStatus(data.status)),
                    ],
                  ),

                  SizedBox(height: 6.h),

                  /// LOCATION
                  Row(
                    children: [
                      Icon(
                        Icons.location_on_outlined,
                        size: 16.sp,
                        color: const Color(0xFF64748B),
                      ),
                      SizedBox(width: 4.w),
                      Expanded(
                        child: Text(
                          data.description.isNotEmpty
                              ? data.description
                              : '${data.latitude.toStringAsFixed(4)}, ${data.longitude.toStringAsFixed(4)}',
                          style: GoogleFonts.inter(
                            fontSize: 14.sp,
                            fontWeight: FontWeight.w400,
                            color: const Color(0xFF64748B),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),

                  SizedBox(height: 4.h),

                  /// TIME
                  Row(
                    children: [
                      Icon(
                        Icons.calendar_today_outlined,
                        size: 14.sp,
                        color: const Color(0xFF64748B),
                      ),
                      SizedBox(width: 4.w),
                      Text(
                        _timeAgo(data.createdAt),
                        style: GoogleFonts.inter(
                          fontSize: 14.sp,
                          fontWeight: FontWeight.w400,
                          color: const Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            /// LITTLE BAR
            Container(
              width: 12.w,
              height: 3.h,
              margin: EdgeInsets.only(left: 6.w),
              decoration: BoxDecoration(
                color: const Color(0xFFD9D9D9),
                borderRadius: BorderRadius.circular(2.r),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// CHIP BUILDER
  Widget _buildStatusChip(IssueStatus status) {
    late Color bg;
    late Color border;
    late Color text;
    late String label;

    switch (status) {
      case IssueStatus.reported:
        bg = const Color(0x1AF0B100);
        border = const Color(0x33F0B100);
        text = const Color(0xFFD08700);
        label = "Reported";
        break;

      case IssueStatus.underRepair:
        bg = const Color(0x1A2B7FFF);
        border = const Color(0x332B7FFF);
        text = const Color(0xFF155DFC);
        label = "Under Repair";
        break;

      case IssueStatus.fixed:
        bg = const Color(0x1A10B981);
        border = const Color(0x3310B981);
        text = const Color(0xFF10B981);
        label = "Fixed";
        break;
    }

    return Container(
      height: 26.h,
      padding: EdgeInsets.symmetric(horizontal: 10.w),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(100.r),
        border: Border(top: BorderSide(color: border, width: 1.18)),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 12.sp,
          fontWeight: FontWeight.w600,
          color: text,
        ),
      ),
    );
  }
}
