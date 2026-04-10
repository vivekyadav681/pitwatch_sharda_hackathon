// Model for storing pothole detections
enum PotholeStatus { reported, underRepair, fixed, pending, unknown }

String _statusToString(PotholeStatus s) {
  switch (s) {
    case PotholeStatus.reported:
      return 'reported';
    case PotholeStatus.underRepair:
      return 'underRepair';
    case PotholeStatus.fixed:
      return 'fixed';
    case PotholeStatus.pending:
      return 'pending';
    case PotholeStatus.unknown:
      return 'unknown';
  }
}

PotholeStatus _statusFromString(String? s) {
  if (s == null) return PotholeStatus.unknown;
  final lower = s.toLowerCase();
  if (lower == 'reported') return PotholeStatus.reported;
  if (lower == 'underrepair' ||
      lower == 'under_repair' ||
      lower == 'underRepair')
    return PotholeStatus.underRepair;
  if (lower == 'fixed') return PotholeStatus.fixed;
  if (lower == 'pending') return PotholeStatus.pending;
  return PotholeStatus.unknown;
}

class PotholeDetection {
  final int id;
  final String title;
  final String description;
  final PotholeStatus status;
  final double latitude;
  final double longitude;
  final String createdAt;

  PotholeDetection({
    required this.id,
    required this.title,
    required this.description,
    required this.status,
    required this.latitude,
    required this.longitude,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'description': description,
    'status': _statusToString(status),
    'latitude': latitude,
    'longitude': longitude,
    'created_at': createdAt,
  };

  factory PotholeDetection.fromJson(Map<String, dynamic> json) =>
      PotholeDetection(
        id: json['id'] as int,
        title: json['title'] as String,
        description: json['description'] as String,
        status: _statusFromString(json['status'] as String?),
        latitude: (json['latitude'] as num).toDouble(),
        longitude: (json['longitude'] as num).toDouble(),
        createdAt: json['created_at'] as String,
      );
}

// UI-friendly status and mapper
enum IssueStatus { reported, underRepair, fixed }

IssueStatus mapPotholeStatus(PotholeStatus s) {
  switch (s) {
    case PotholeStatus.fixed:
      return IssueStatus.fixed;
    case PotholeStatus.underRepair:
      return IssueStatus.underRepair;
    case PotholeStatus.reported:
    case PotholeStatus.pending:
    case PotholeStatus.unknown:
    default:
      return IssueStatus.reported;
  }
}
