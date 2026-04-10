import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pitwatch/models/pothole.dart';
import 'package:pitwatch/services/report_service.dart';

class PotholeNotifier extends StateNotifier<List<PotholeDetection>> {
  PotholeNotifier() : super([]);

  static const _kReportsKey = 'cached_reports_v1';
  // Session-only detections (maps) collected during an active session.
  final List<Map<String, dynamic>> _sessionDetections = [];

  /// Total detections stored in the provider (persistent cache) or
  /// a server-provided total if available. When `_totalCount` is null the
  /// provider falls back to the local list length.
  int get totalCount => _totalCount ?? state.length;

  /// Number of detections captured in the current session
  int get sessionCount => _sessionDetections.length;

  /// Expose session detections as an immutable list
  List<Map<String, dynamic>> get sessionDetections =>
      List.unmodifiable(_sessionDetections);

  /// Add a persisted detection to the global list (avoids duplicates by id)
  void addDetection(PotholeDetection detection) {
    final exists = state.any((d) => d.id == detection.id);
    if (exists) return;
    state = [...state, detection];
    saveToPrefs();
  }

  /// Add a detection map to the current session (not persisted)
  void addSessionDetection(Map<String, dynamic> detection) {
    _sessionDetections.add(detection);
    // notify listeners by reassigning state (no-op change to persisted list)
    state = [...state];
  }

  /// Merge session detections into the persisted list, converting maps
  /// to `PotholeDetection` and deduplicating by id.
  Future<void> mergeSessionIntoState() async {
    final existingIds = state.map((e) => e.id).toSet();
    final parsed = <PotholeDetection>[];
    for (final raw in _sessionDetections) {
      try {
        final m = Map<String, dynamic>.from(raw);
        final candidate = PotholeDetection.fromJson(m);
        if (existingIds.contains(candidate.id)) continue;
        parsed.add(candidate);
        existingIds.add(candidate.id);
      } catch (_) {
        // skip malformed session item
      }
    }
    if (parsed.isNotEmpty) {
      state = [...state, ...parsed];
      await saveToPrefs();
    }
    _sessionDetections.clear();
    state = [...state];
  }

  int get last30DaysCount {
    final cutoff = DateTime.now().subtract(const Duration(days: 30));
    return state.where((d) {
      try {
        return DateTime.parse(d.createdAt).isAfter(cutoff);
      } catch (_) {
        return false;
      }
    }).length;
  }

  // Compatibility shims for older callers -----------------------------------------------------------------
  /// Increment a lightweight local count (kept as a no-op shim).
  void incrementCountBy(int n) {
    if (n <= 0) return;
    // no-op for simplified provider; trigger listeners
    state = [...state];
  }

  // Backing field for a server-provided total count. When zero, fall back
  // to using `state.length`.
  int? _totalCount;
  bool _countsLoading = false;

  /// Set a single server-provided total count.
  void setServerCount(int c) {
    _totalCount = c;
    state = [...state];
  }

  bool get countsLoading => _countsLoading;

  /// Fetch counts from server and update the single total count value.
  Future<void> fetchAndSetCounts() async {
    _countsLoading = true;
    state = [...state];
    try {
      final res = await ReportService.fetchCounts();
      if (res['ok'] == true && res['counts'] is Map<String, dynamic>) {
        final raw = res['counts'] as Map<String, dynamic>;
        var total = 0;
        raw.forEach((k, v) {
          if (v is num)
            total += v.toInt();
          else if (v is String)
            total += int.tryParse(v) ?? 0;
        });
        setServerCount(total);
      }
    } catch (_) {}
    _countsLoading = false;
    state = [...state];
  }

  /// (removed) virtual count functionality; use session detections instead.

  /// Add multiple detections from a list of detection maps or PotholeDetection
  /// objects. Maps will be converted using `PotholeDetection.fromJson`.
  void addFromMaps(List<Map<String, dynamic>> maps) {
    if (maps.isEmpty) return;

    final parsed = <PotholeDetection>[];
    final existingIds = state.map((e) => e.id).toSet();

    for (final raw in maps) {
      try {
        // Normalize common key variations into the shape expected by
        // PotholeDetection.fromJson.
        final Map<String, dynamic> m = Map<String, dynamic>.from(raw);

        // createdAt vs created_at
        if (m.containsKey('createdAt') && !m.containsKey('created_at')) {
          m['created_at'] = m['createdAt'];
        }

        // latitude/longitude variants
        if (!m.containsKey('latitude') && m.containsKey('lat')) {
          m['latitude'] = m['lat'];
        }
        if (!m.containsKey('longitude') && m.containsKey('lon')) {
          m['longitude'] = m['lon'];
        }
        if (!m.containsKey('longitude') && m.containsKey('lng')) {
          m['longitude'] = m['lng'];
        }

        // status may come as enum or differently named key
        if (!m.containsKey('status') && m.containsKey('state')) {
          m['status'] = m['state'];
        }

        // id may be string; try to coerce to int
        if (m.containsKey('id') && m['id'] is String) {
          final v = int.tryParse(m['id'] as String);
          if (v != null) m['id'] = v;
        }

        // If id missing, try to create a stable id from lat/lon/created_at
        if (!m.containsKey('id') || m['id'] == null) {
          final lat = (m['latitude'] is num)
              ? (m['latitude'] as num).toDouble()
              : 0.0;
          final lon = (m['longitude'] is num)
              ? (m['longitude'] as num).toDouble()
              : 0.0;
          final created = (m['created_at'] ?? '').toString();
          m['id'] =
              (lat.toStringAsFixed(6) +
                      '|' +
                      lon.toStringAsFixed(6) +
                      '|' +
                      created)
                  .hashCode;
        }

        // Ensure minimal required fields exist
        if (!m.containsKey('title') ||
            !m.containsKey('description') ||
            !m.containsKey('created_at')) {
          // skip incomplete item
          continue;
        }

        final candidate = PotholeDetection.fromJson(m);

        // Deduplicate by id or by very close coordinates + timestamp
        if (existingIds.contains(candidate.id)) continue;

        final duplicateNearby = state.any((e) {
          final sameTime = (e.createdAt == candidate.createdAt);
          final latEq = (e.latitude - candidate.latitude).abs() < 0.0001;
          final lonEq = (e.longitude - candidate.longitude).abs() < 0.0001;
          return sameTime && latEq && lonEq;
        });
        if (duplicateNearby) continue;

        parsed.add(candidate);
        existingIds.add(candidate.id);
      } catch (_) {
        // ignore parse errors and skip item
      }
    }

    if (parsed.isNotEmpty) state = [...state, ...parsed];
    // persist cache
    saveToPrefs();
  }

  /// Fetch reports from the remote API and replace current state with
  /// the fetched detections. If the request fails the state is unchanged.
  Future<void> fetchReports({int page = 1, int pageSize = 1000}) async {
    try {
      final res = await ReportService.fetchReports(
        page: page,
        pageSize: pageSize,
      );
      if (res['ok'] == true && res['data'] is Map<String, dynamic>) {
        final jsonBody = res['data'] as Map<String, dynamic>;
        final results = jsonBody['results'] as List<dynamic>? ?? [];
        final parsed = <PotholeDetection>[];
        for (final item in results) {
          if (item is Map<String, dynamic>) {
            try {
              parsed.add(PotholeDetection.fromJson(item));
            } catch (_) {
              // ignore malformed item
            }
          }
        }
        // Replace current detections with fetched ones
        state = parsed;
        // Use the fetched list length as the authoritative total count.
        setServerCount(parsed.length);
        // cache to prefs
        await saveToPrefs();
      }
    } catch (_) {
      // ignore network / parse errors for now
    }
  }

  /// Save current state to SharedPreferences as JSON array
  Future<void> saveToPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = state.map((e) => e.toJson()).toList();
      await prefs.setString(_kReportsKey, jsonEncode(list));
      // keep persistence minimal: only cached reports
    } catch (_) {
      // ignore
    }
  }

  /// Load cached detections from SharedPreferences into state
  Future<void> loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kReportsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw) as List<dynamic>;
      final parsed = <PotholeDetection>[];
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          try {
            parsed.add(PotholeDetection.fromJson(item));
          } catch (_) {}
        }
      }
      if (parsed.isNotEmpty) state = parsed;
      // session detections start empty
    } catch (_) {
      // ignore
    }
  }

  void clear() {
    state = [];
    _sessionDetections.clear();
    saveToPrefs();
  }
}

final potholeProvider =
    StateNotifierProvider<PotholeNotifier, List<PotholeDetection>>(
      (ref) => PotholeNotifier(),
    );

/// Total persisted detections
final totalDetectionsProvider = Provider<int>((ref) {
  final notifier = ref.watch(potholeProvider.notifier);
  return notifier.totalCount;
});

/// Count of detections captured in the current session
final sessionCountProvider = Provider<int>((ref) {
  final notifier = ref.watch(potholeProvider.notifier);
  return notifier.sessionCount;
});

/// Session detections as maps
final sessionDetectionsProvider = Provider<List<Map<String, dynamic>>>((ref) {
  final notifier = ref.watch(potholeProvider.notifier);
  return notifier.sessionDetections;
});

/// Helper: last 30 days from persisted detections
final last30DaysCountProvider = Provider<int>((ref) {
  final list = ref.watch(potholeProvider);
  final cutoff = DateTime.now().subtract(const Duration(days: 30));
  return list.where((d) {
    try {
      return DateTime.parse(d.createdAt).isAfter(cutoff);
    } catch (_) {
      return false;
    }
  }).length;
});

// Compatibility providers and session-level notifier (kept for existing UI code)
class SessionPotholesNotifier
    extends StateNotifier<List<Map<String, dynamic>>> {
  SessionPotholesNotifier() : super([]);

  void add(Map<String, dynamic> detection) {
    state = [...state, detection];
  }

  void clear() {
    state = [];
  }

  int get count => state.length;
}

final sessionPotholesProvider =
    StateNotifierProvider<SessionPotholesNotifier, List<Map<String, dynamic>>>(
      (ref) => SessionPotholesNotifier(),
    );

final sessionPotholesCountProvider = Provider<int>((ref) {
  return ref.watch(sessionPotholesProvider).length;
});

/// Backwards-compatible total count provider
final totalCountProvider = Provider<int>((ref) {
  final notifier = ref.watch(potholeProvider.notifier);
  return notifier.totalCount;
});

/// Approximation for server-provided count (legacy name)
final reportsApiCountProvider = Provider<int>((ref) {
  final notifier = ref.watch(potholeProvider.notifier);
  return notifier.totalCount;
});

final reportsStatusTotalProvider = Provider<int>((ref) {
  final notifier = ref.watch(potholeProvider.notifier);
  return notifier.totalCount;
});

final reportsCountsLoadingProvider = Provider<bool>((ref) {
  final notifier = ref.watch(potholeProvider.notifier);
  return notifier.countsLoading;
});
