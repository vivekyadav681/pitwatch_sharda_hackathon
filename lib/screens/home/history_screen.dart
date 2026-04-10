import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:pitwatch/models/pothole.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pitwatch/providers/pothole_provider.dart';
import 'package:pitwatch/services/report_service.dart';
import 'package:pitwatch/widgets/issue_card.dart';

enum FilterStatus { all, reported, fixed, inProgress }

class DetectionHistoryScreen extends ConsumerStatefulWidget {
  const DetectionHistoryScreen({super.key});

  @override
  ConsumerState<DetectionHistoryScreen> createState() =>
      _DetectionHistoryScreenState();
}

class _DetectionHistoryScreenState
    extends ConsumerState<DetectionHistoryScreen> {
  FilterStatus selectedFilter = FilterStatus.all;
  bool _loading = true;
  String? _errorMessage;

  Future<void> _loadReports() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });
    try {
      // Migrate any session detections into global provider first
      final existing = ref.read(sessionPotholesProvider);
      if (existing.isNotEmpty) {
        ref.read(potholeProvider.notifier).addFromMaps(existing);
      }
      ref.read(sessionPotholesProvider.notifier).clear();

      // Fetch persisted reports from server (uses ReportService for auth)
      final resp = await ReportService.fetchReports(page: 1, pageSize: 50);
      if (resp['ok'] == true && resp['data'] is Map<String, dynamic>) {
        final data = resp['data'] as Map<String, dynamic>;
        final count = (data['count'] is int)
            ? data['count'] as int
            : int.tryParse('${data['count']}') ?? 0;
        final results = data['results'] as List<dynamic>? ?? [];

        // Replace provider state with fetched results
        ref.read(potholeProvider.notifier).clear();
        final maps = <Map<String, dynamic>>[];
        for (final item in results) {
          if (item is Map<String, dynamic>) maps.add(item);
        }
        if (maps.isNotEmpty)
          ref.read(potholeProvider.notifier).addFromMaps(maps);
        // store server count in provider for Home screen use
        ref.read(potholeProvider.notifier).setServerCount(count);
      } else {
        // fallback to notifier fetch if the service call failed
        await ref.read(potholeProvider.notifier).fetchReports();
      }
    } catch (e) {
      debugPrint('Failed to load reports: $e');
      _errorMessage = 'Failed to load reports';
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    // Migrate any in-session detections into global provider once on first open.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        final existing = ref.read(sessionPotholesProvider);
        if (existing.isNotEmpty) {
          ref.read(potholeProvider.notifier).addFromMaps(existing);
        }
        ref.read(sessionPotholesProvider.notifier).clear();
      } catch (_) {}
      // Load persisted reports on first open so the loading spinner can stop.
      _loadReports();
    });
  }

  List<PotholeDetection> _filteredIssuesFromDetections(
    List<PotholeDetection> detections,
  ) {
    final list = detections;
    if (selectedFilter == FilterStatus.all) return list;

    return list.where((issue) {
      final s = mapPotholeStatus(issue.status);
      switch (selectedFilter) {
        case FilterStatus.reported:
          return s == IssueStatus.reported;
        case FilterStatus.fixed:
          return s == IssueStatus.fixed;
        case FilterStatus.inProgress:
          return s == IssueStatus.underRepair;
        case FilterStatus.all:
          return true;
      }
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final detections = ref.watch(potholeProvider);
    final filtered = _filteredIssuesFromDetections(detections);

    return Stack(
      children: [
        /// TOP GRADIENT (same as HomeScreen)
        Container(
          width: double.infinity,
          height: 150.h,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(-1, -0.5),
              end: Alignment(1, 1),
              colors: [Color(0xFF1E3A8A), Color(0xFF3470DA)],
            ),
          ),
        ),

        SafeArea(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 24.w, vertical: 12.h),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.fromLTRB(0, 8.h, 0, 8.h),
                  child: Text(
                    "Detection History",
                    style: GoogleFonts.inter(
                      fontSize: 28.sp,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),

                // Filter card (fixed above list)
                Center(
                  child: Transform.translate(
                    offset: Offset(0, -5.h),
                    child: FilterCard(
                      onChanged: (status) {
                        setState(() {
                          selectedFilter = status;
                        });
                      },
                    ),
                  ),
                ),

                SizedBox(height: 8.h),

                // Scrollable list of detections or loader while fetching; pull-to-refresh triggers _loadReports
                Expanded(
                  child: _loading
                      ? Center(
                          child: CircularProgressIndicator(
                            valueColor: AlwaysStoppedAnimation(
                              const Color(0xFF1E3A8A),
                            ),
                          ),
                        )
                      : (_errorMessage != null
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(_errorMessage!),
                                    SizedBox(height: 12.h),
                                    ElevatedButton(
                                      onPressed: _loadReports,
                                      child: const Text('Retry'),
                                    ),
                                  ],
                                ),
                              )
                            : RefreshIndicator(
                                onRefresh: _loadReports,
                                color: const Color(0xFF1E3A8A),
                                child: ListView.builder(
                                  physics:
                                      const AlwaysScrollableScrollPhysics(),
                                  padding: EdgeInsets.zero,
                                  itemCount: filtered.length + 1,
                                  itemBuilder: (context, index) {
                                    if (index < filtered.length) {
                                      final issue = filtered[index];
                                      return Padding(
                                        padding: EdgeInsets.only(bottom: 12.h),
                                        child: IssueCard(data: issue),
                                      );
                                    }
                                    // footer with counts/spacing
                                    return Padding(
                                      padding: EdgeInsets.symmetric(
                                        vertical: 20.h,
                                      ),
                                      child: Column(
                                        children: [
                                          Text(
                                            "Showing ${filtered.length} of ${ref.watch(totalCountProvider)} detections",
                                            style: GoogleFonts.inter(
                                              fontSize: 12.sp,
                                              color: const Color(0xFF64748B),
                                            ),
                                          ),
                                          SizedBox(height: 40.h),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              )),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class FilterCard extends StatefulWidget {
  final Function(FilterStatus)? onChanged;

  const FilterCard({super.key, this.onChanged});

  @override
  State<FilterCard> createState() => _FilterCardState();
}

class _FilterCardState extends State<FilterCard> {
  FilterStatus selected = FilterStatus.all;

  void select(FilterStatus status) {
    setState(() => selected = status);
    widget.onChanged?.call(status);
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 312.w,
        height: 150.h,
        padding: EdgeInsets.all(16.w),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16.r),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.25),
              blurRadius: 24.8,
              offset: const Offset(0, 13),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            /// TITLE
            Row(
              children: [
                Icon(
                  Icons.filter_list_rounded,
                  size: 16.sp,
                  color: const Color(0xFF64748B),
                ),
                SizedBox(width: 8.w),
                Text(
                  "Filter by status",
                  style: GoogleFonts.inter(
                    fontSize: 14.sp,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF64748B),
                  ),
                ),
              ],
            ),

            SizedBox(height: 16.h),

            /// CHIPS (CORRECT LAYOUT)
            Wrap(
              spacing: 40.w,
              runSpacing: 10.h,
              children: [
                _chip("All", FilterStatus.all),
                _chip("Reported", FilterStatus.reported),
                _chip("Fixed", FilterStatus.fixed),
                _chip("In Progress", FilterStatus.inProgress),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String text, FilterStatus status) {
    final isSelected = selected == status;

    final Color bgColor;
    final Color textColor;

    if (isSelected) {
      switch (status) {
        case FilterStatus.all:
          bgColor = const Color(0xFF1E3A8A);
          break;
        case FilterStatus.reported:
          bgColor = const Color(0xFFF0B100);
          break;
        case FilterStatus.fixed:
          bgColor = const Color(0xFF10B981);
          break;
        case FilterStatus.inProgress:
          bgColor = const Color(0xFF2B7FFF);
          break;
      }
      textColor = Colors.white;
    } else {
      bgColor = const Color(0xFFF1F5F9);
      textColor = const Color(0xFF64748B);
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16.r),
        onTap: () => select(status),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 6.h),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(16.r),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.25),
                      offset: const Offset(0, 2),
                      blurRadius: 4.6,
                      spreadRadius: 0,
                    ),
                  ]
                : [],
          ),
          child: Text(
            text,
            style: GoogleFonts.inter(
              fontSize: 14.sp,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
        ),
      ),
    );
  }
}

// IssueStatus moved to models/pothole.dart

class IssueModel {
  final String title;
  final String location;
  final String time;
  final IssueStatus status;

  IssueModel({
    required this.title,
    required this.location,
    required this.time,
    required this.status,
  });
}
