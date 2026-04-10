import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pitwatch/models/pothole.dart';
import 'package:pitwatch/services/report_service.dart';

class PotholeNotifier extends StateNotifier<List<PotholeDetection>> {
  PotholeNotifier() : super([]);

  static const _kReportsKey = 'cached_reports_v1';
  static const _kReportsVirtualCountKey = 'cached_reports_v1_virtual_count';
  static const _kReportsServerCountKey = 'cached_reports_v1_server_count';

  int _virtualCount = 0;
  int _serverCount = 0;
  Map<String, int> _statusCounts = {};
  bool _countsLoading = false;

  int get totalCount => state.length + _virtualCount;

  int get serverCount => _serverCount;

  /// Status counts returned from the API (e.g. pending/rejected/resolved)
  Map<String, int> get statusCounts => Map.unmodifiable(_statusCounts);

  int get statusCountsTotal =>
      _statusCounts.values.fold<int>(0, (prev, v) => prev + (v ?? 0));

  bool get countsLoading => _countsLoading;

  void setServerCount(int c) {
    _serverCount = c;
    // write prefs and notify listeners by re-assigning state (no-op change)
    saveToPrefs();
    state = [...state];
  }

  /// Set status counts map and persist.
  void setStatusCounts(Map<String, int> counts) {
    _statusCounts = Map<String, int>.from(counts);
    saveToPrefs();
    // trigger listeners
    state = [...state];
  }

  /// Fetch counts from the API and update provider state. This will set
  /// `countsLoading` while the network call is in progress.
  Future<void> fetchAndSetCounts() async {
    _countsLoading = true;
    state = [...state];
    try {
      final res = await ReportService.fetchCounts();
      if (res['ok'] == true && res['data'] is Map<String, int>) {
        setStatusCounts(Map<String, int>.from(res['data']));
      } else {
        // on error, clear counts and optionally persist empty map
        setStatusCounts({});
      }
    } catch (_) {}
    _countsLoading = false;
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

  void addDetection(PotholeDetection detection) {
    // Avoid adding duplicate by `id`.
    final exists = state.any((d) => d.id == detection.id);
    if (exists) return;
    state = [...state, detection];
    saveToPrefs();
  }

  /// Increment a lightweight local count representing detections that
  /// should be counted but not stored as full detection objects.
  void incrementCountBy(int n) {
    if (n <= 0) return;
    _virtualCount += n;
    saveToPrefs();
  }

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
  Future<void> fetchReports() async {
    try {
      final uri = Uri.parse('https://pitwatch.onrender.com/api/v1/reports/');
      final resp = await http.get(uri);
      if (resp.statusCode == 200) {
        final jsonBody = jsonDecode(resp.body) as Map<String, dynamic>;
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
      await prefs.setInt(_kReportsVirtualCountKey, _virtualCount);
      await prefs.setInt(_kReportsServerCountKey, _serverCount);
      // save status counts
      try {
        await prefs.setString(
          '${_kReportsKey}_status_counts',
          jsonEncode(_statusCounts),
        );
      } catch (_) {}
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
      // load virtual count (default 0)
      try {
        _virtualCount = prefs.getInt(_kReportsVirtualCountKey) ?? 0;
      } catch (_) {
        _virtualCount = 0;
      }
      try {
        _serverCount = prefs.getInt(_kReportsServerCountKey) ?? 0;
      } catch (_) {
        _serverCount = 0;
      }
      try {
        final rawCounts = prefs.getString('${_kReportsKey}_status_counts');
        if (rawCounts != null && rawCounts.isNotEmpty) {
          final decoded = jsonDecode(rawCounts) as Map<String, dynamic>;
          _statusCounts = decoded.map(
            (k, v) => MapEntry(
              k,
              (v is num) ? v.toInt() : int.tryParse(v.toString()) ?? 0,
            ),
          );
        }
      } catch (_) {
        _statusCounts = {};
      }
    } catch (_) {
      // ignore
    }
  }

  void clear() {
    state = [];
    _virtualCount = 0;
    _serverCount = 0;
    saveToPrefs();
  }
}

final potholeProvider =
    StateNotifierProvider<PotholeNotifier, List<PotholeDetection>>(
      (ref) => PotholeNotifier(),
    );

final totalCountProvider = Provider<int>((ref) {
  // include virtual count when reporting total
  final list = ref.watch(potholeProvider);
  // Access the notifier to read private virtual count via exposed totalCount
  final notifier = ref.read(potholeProvider.notifier);
  return notifier.totalCount;
});

/// Server-provided total reports count (from API `count` field)
final reportsApiCountProvider = Provider<int>((ref) {
  final notifier = ref.watch(potholeProvider.notifier);
  return notifier.serverCount;
});

/// Provider exposing status counts map (pending/rejected/resolved)
final reportsStatusCountsProvider = Provider<Map<String, int>>((ref) {
  final notifier = ref.watch(potholeProvider.notifier);
  return notifier.statusCounts;
});

/// Provider exposing total of status counts
final reportsStatusTotalProvider = Provider<int>((ref) {
  final notifier = ref.watch(potholeProvider.notifier);
  return notifier.statusCountsTotal;
});

/// Provider exposing whether counts are loading
final reportsCountsLoadingProvider = Provider<bool>((ref) {
  final notifier = ref.watch(potholeProvider.notifier);
  return notifier.countsLoading;
});

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

// Session-level potholes: stores full detection maps for the current session
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
