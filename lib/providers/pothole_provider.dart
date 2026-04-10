import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pitwatch/models/pothole.dart';

class PotholeNotifier extends StateNotifier<List<PotholeDetection>> {
  PotholeNotifier() : super([]);

  static const _kReportsKey = 'cached_reports_v1';
  static const _kReportsVirtualCountKey = 'cached_reports_v1_virtual_count';
  static const _kReportsServerCountKey = 'cached_reports_v1_server_count';

  int _virtualCount = 0;
  int _serverCount = 0;

  int get totalCount => state.length + _virtualCount;

  int get serverCount => _serverCount;

  void setServerCount(int c) {
    _serverCount = c;
    // write prefs and notify listeners by re-assigning state (no-op change)
    saveToPrefs();
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
    for (final m in maps) {
      try {
        parsed.add(PotholeDetection.fromJson(m));
      } catch (_) {
        // ignore parse errors
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
