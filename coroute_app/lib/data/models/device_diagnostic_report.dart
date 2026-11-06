import 'dart:convert';

/// Status of an individual diagnostic check or category.
class DiagnosticStatus {
  static const String supported = 'Supported';
  static const String ready = 'Ready';
  static const String limited = 'Limited';
  static const String permissionRequired = 'Permission Required';
  static const String unsupported = 'Unsupported';
  static const String notTested = 'Not Tested';
  static const String failed = 'Failed';

  static const List<String> values = [
    supported,
    ready,
    limited,
    permissionRequired,
    unsupported,
    notTested,
    failed,
  ];

  static bool isValid(String val) => values.contains(val);
}

/// Overall diagnostic rating for the rider's phone and setup.
/// STRICT RULE: No fake percentages/scores.
class DiagnosticOverallResult {
  static const String fullySupported = 'Fully supported';
  static const String supportedWithLimitations = 'Supported with limitations';
  static const String limitedCompatibility = 'Limited compatibility';
  static const String criticalIssueDetected = 'Critical issue detected';

  static const List<String> values = [
    fullySupported,
    supportedWithLimitations,
    limitedCompatibility,
    criticalIssueDetected,
  ];

  static bool isValid(String val) => values.contains(val);
}

/// Lifecycle status for diagnostic reports.
class DiagnosticLifecycleStatus {
  static const String created = 'Created';
  static const String completed = 'Completed';
  static const String pendingSubmission = 'Pending Submission';
  static const String submitted = 'Submitted';
  static const String failed = 'Failed';
  static const String reviewed = 'Reviewed';
  static const String resolved = 'Resolved';

  static const List<String> values = [
    created,
    completed,
    pendingSubmission,
    submitted,
    failed,
    reviewed,
    resolved,
  ];

  static bool isValid(String val) => values.contains(val);
}

/// Plain result of one pre-ride check, as the rider sees it.
enum CheckVerdict { pass, warn, fail }

/// Overall pre-ride verdict. Nothing is ever blocked: [notReady] asks the rider to fix or
/// knowingly ride anyway.
enum RideReadiness { ready, readyWithWarnings, notReady }

/// One-tap fixes the pre-ride phone check offers (stored in a check's `metadata['fix']`).
class PhoneCheckFix {
  PhoneCheckFix._();
  static const String locationService = 'locationService';
  static const String location = 'location';
  static const String locationAlways = 'locationAlways';
  static const String preciseLocation = 'preciseLocation';
  static const String notification = 'notification';
  static const String microphone = 'microphone';
  static const String bluetooth = 'bluetooth';
  static const String battery = 'battery';
  static const String oemBattery = 'oemBattery';
  static const String fullScreen = 'fullScreen';
  static const String sound = 'sound';
  static const String appSettings = 'appSettings';
  static const String crashDetection = 'crashDetection';
  static const String retry = 'retry';
}

/// A single check within a diagnostic category.
class DiagnosticCheckItem {
  final String key;
  final String name;
  final String status;
  final String detail;
  final bool isCritical;
  final Map<String, dynamic>? metadata;

  const DiagnosticCheckItem({
    required this.key,
    required this.name,
    required this.status,
    required this.detail,
    this.isCritical = false,
    this.metadata,
  });

  /// pass / warn / fail. A failed or missing *critical* item is a fail; any other problem
  /// (or an item that could not be tested) is a warning.
  CheckVerdict get verdict {
    switch (status) {
      case DiagnosticStatus.ready:
      case DiagnosticStatus.supported:
        return CheckVerdict.pass;
      case DiagnosticStatus.failed:
      case DiagnosticStatus.unsupported:
      case DiagnosticStatus.permissionRequired:
        return isCritical ? CheckVerdict.fail : CheckVerdict.warn;
      default:
        return CheckVerdict.warn;
    }
  }

  /// The one-tap fix for this item ([PhoneCheckFix]), or null.
  String? get fix {
    final f = metadata?['fix'];
    return f is String && f.isNotEmpty ? f : null;
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'name': name,
        'status': status,
        'detail': detail,
        'isCritical': isCritical,
        if (metadata != null) 'metadata': metadata,
      };

  factory DiagnosticCheckItem.fromJson(Map<String, dynamic> json) {
    return DiagnosticCheckItem(
      key: json['key']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      status: json['status']?.toString() ?? DiagnosticStatus.notTested,
      detail: json['detail']?.toString() ?? '',
      isCritical: json['isCritical'] == true,
      metadata: json['metadata'] is Map ? Map<String, dynamic>.from(json['metadata'] as Map) : null,
    );
  }
}

/// A group of diagnostic checks representing a functional category.
class DiagnosticCategoryResult {
  final String categoryKey;
  final String title;
  final String status;
  final String summary;
  final List<DiagnosticCheckItem> checks;

  const DiagnosticCategoryResult({
    required this.categoryKey,
    required this.title,
    required this.status,
    required this.summary,
    required this.checks,
  });

  Map<String, dynamic> toJson() => {
        'categoryKey': categoryKey,
        'title': title,
        'status': status,
        'summary': summary,
        'checks': checks.map((c) => c.toJson()).toList(),
      };

  factory DiagnosticCategoryResult.fromJson(Map<String, dynamic> json) {
    return DiagnosticCategoryResult(
      categoryKey: json['categoryKey']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      status: json['status']?.toString() ?? DiagnosticStatus.notTested,
      summary: json['summary']?.toString() ?? '',
      checks: (json['checks'] as List<dynamic>? ?? [])
          .whereType<Map>()
          .map((c) => DiagnosticCheckItem.fromJson(Map<String, dynamic>.from(c)))
          .toList(),
    );
  }
}

/// Device hardware and OS specs collected for diagnostics.
/// Prohibited fields (IMEI, serial numbers) are NEVER collected or stored.
class DiagnosticDeviceInfo {
  final String manufacturer;
  final String model;
  final String osVersion;
  final int apiLevel;
  final String appVersion;
  final String buildNumber;
  final String cpuArch;
  final String batteryOptimizationStatus;

  const DiagnosticDeviceInfo({
    required this.manufacturer,
    required this.model,
    required this.osVersion,
    required this.apiLevel,
    required this.appVersion,
    required this.buildNumber,
    required this.cpuArch,
    required this.batteryOptimizationStatus,
  });

  Map<String, dynamic> toJson() => {
        'manufacturer': manufacturer,
        'model': model,
        'osVersion': osVersion,
        'apiLevel': apiLevel,
        'appVersion': appVersion,
        'buildNumber': buildNumber,
        'cpuArch': cpuArch,
        'batteryOptimizationStatus': batteryOptimizationStatus,
      };

  factory DiagnosticDeviceInfo.fromJson(Map<String, dynamic> json) {
    return DiagnosticDeviceInfo(
      manufacturer: json['manufacturer']?.toString() ?? 'Unknown',
      model: json['model']?.toString() ?? 'Unknown',
      osVersion: json['osVersion']?.toString() ?? 'Unknown',
      apiLevel: (json['apiLevel'] as num?)?.toInt() ?? 0,
      appVersion: json['appVersion']?.toString() ?? '1.0.0',
      buildNumber: json['buildNumber']?.toString() ?? '1',
      cpuArch: json['cpuArch']?.toString() ?? 'Unknown',
      batteryOptimizationStatus: json['batteryOptimizationStatus']?.toString() ?? 'Unknown',
    );
  }
}

/// Full Pre-Ride Phone Check and Device Diagnostics Report.
class DeviceDiagnosticReport {
  final String diagnosticId;
  final String? riderId;
  final String? riderEmail;
  final int timestamp;
  final DiagnosticDeviceInfo deviceInfo;
  final String overallResult;
  final String overallSummary;
  final String lifecycleStatus;
  final Map<String, DiagnosticCategoryResult> categories;
  final bool consentGiven;
  final int? consentTimestamp;
  final String? adminNotes;
  final List<Map<String, dynamic>> reviewHistory;
  final int? createdAt;
  final int? updatedAt;

  const DeviceDiagnosticReport({
    required this.diagnosticId,
    this.riderId,
    this.riderEmail,
    required this.timestamp,
    required this.deviceInfo,
    required this.overallResult,
    required this.overallSummary,
    this.lifecycleStatus = DiagnosticLifecycleStatus.completed,
    required this.categories,
    this.consentGiven = false,
    this.consentTimestamp,
    this.adminNotes,
    this.reviewHistory = const [],
    this.createdAt,
    this.updatedAt,
  });

  /// Every check of every category, in order.
  List<DiagnosticCheckItem> get allChecks => [for (final c in categories.values) ...c.checks];

  /// Checks that are not a pass, failures first.
  List<DiagnosticCheckItem> get problems {
    final fails = allChecks.where((c) => c.verdict == CheckVerdict.fail);
    final warns = allChecks.where((c) => c.verdict == CheckVerdict.warn);
    return [...fails, ...warns];
  }

  RideReadiness get readiness {
    final checks = allChecks;
    if (checks.any((c) => c.verdict == CheckVerdict.fail)) return RideReadiness.notReady;
    if (checks.any((c) => c.verdict == CheckVerdict.warn)) return RideReadiness.readyWithWarnings;
    return RideReadiness.ready;
  }

  /// Forbidden property names that must NEVER be present anywhere in payload or submission.
  static const Set<String> prohibitedKeys = {
    'imei',
    'serial',
    'serialnumber',
    'contacts',
    'contactlist',
    'messages',
    'smslist',
    'audio',
    'audiorecording',
    'recordedvoice',
    'password',
    'token',
    'refreshtoken',
    'accesstoken',
    'continuousgps',
    'gpstraces',
    'rawcoordinates',
    'exactpath',
  };

  /// Validates that a JSON representation is free from any forbidden keys.
  static bool validatePrivacySafety(Map<String, dynamic> data) {
    bool hasForbidden(dynamic val, [String? currentKey]) {
      if (currentKey != null) {
        final lower = currentKey.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
        for (final p in prohibitedKeys) {
          if (lower.contains(p)) return true;
        }
      }
      if (val is Map) {
        for (final entry in val.entries) {
          if (hasForbidden(entry.value, entry.key.toString())) return true;
        }
      } else if (val is List) {
        for (final item in val) {
          if (hasForbidden(item)) return true;
        }
      }
      return false;
    }

    return !hasForbidden(data);
  }

  DeviceDiagnosticReport copyWith({
    String? diagnosticId,
    String? riderId,
    String? riderEmail,
    int? timestamp,
    DiagnosticDeviceInfo? deviceInfo,
    String? overallResult,
    String? overallSummary,
    String? lifecycleStatus,
    Map<String, DiagnosticCategoryResult>? categories,
    bool? consentGiven,
    int? consentTimestamp,
    String? adminNotes,
    List<Map<String, dynamic>>? reviewHistory,
    int? createdAt,
    int? updatedAt,
  }) {
    return DeviceDiagnosticReport(
      diagnosticId: diagnosticId ?? this.diagnosticId,
      riderId: riderId ?? this.riderId,
      riderEmail: riderEmail ?? this.riderEmail,
      timestamp: timestamp ?? this.timestamp,
      deviceInfo: deviceInfo ?? this.deviceInfo,
      overallResult: overallResult ?? this.overallResult,
      overallSummary: overallSummary ?? this.overallSummary,
      lifecycleStatus: lifecycleStatus ?? this.lifecycleStatus,
      categories: categories ?? this.categories,
      consentGiven: consentGiven ?? this.consentGiven,
      consentTimestamp: consentTimestamp ?? this.consentTimestamp,
      adminNotes: adminNotes ?? this.adminNotes,
      reviewHistory: reviewHistory ?? this.reviewHistory,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    final map = {
      'diagnosticId': diagnosticId,
      if (riderId != null) 'riderId': riderId,
      if (riderEmail != null) 'riderEmail': riderEmail,
      'timestamp': timestamp,
      'deviceInfo': deviceInfo.toJson(),
      'overallResult': overallResult,
      'overallSummary': overallSummary,
      'lifecycleStatus': lifecycleStatus,
      'categories': categories.map((k, v) => MapEntry(k, v.toJson())),
      'consentGiven': consentGiven,
      if (consentTimestamp != null) 'consentTimestamp': consentTimestamp,
      if (adminNotes != null) 'adminNotes': adminNotes,
      'reviewHistory': reviewHistory,
      'createdAt': createdAt ?? timestamp,
      'updatedAt': updatedAt ?? timestamp,
    };
    return map;
  }

  factory DeviceDiagnosticReport.fromJson(Map<String, dynamic> json) {
    final catMap = <String, DiagnosticCategoryResult>{};
    if (json['categories'] is Map) {
      final rawCats = json['categories'] as Map;
      rawCats.forEach((k, v) {
        if (v is Map) {
          catMap[k.toString()] = DiagnosticCategoryResult.fromJson(Map<String, dynamic>.from(v));
        }
      });
    }

    return DeviceDiagnosticReport(
      diagnosticId: json['diagnosticId']?.toString() ?? '',
      riderId: json['riderId']?.toString(),
      riderEmail: json['riderEmail']?.toString(),
      timestamp: (json['timestamp'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
      deviceInfo: json['deviceInfo'] is Map
          ? DiagnosticDeviceInfo.fromJson(Map<String, dynamic>.from(json['deviceInfo'] as Map))
          : const DiagnosticDeviceInfo(
              manufacturer: 'Unknown',
              model: 'Unknown',
              osVersion: 'Unknown',
              apiLevel: 0,
              appVersion: '1.0.0',
              buildNumber: '1',
              cpuArch: 'Unknown',
              batteryOptimizationStatus: 'Unknown',
            ),
      overallResult: json['overallResult']?.toString() ?? DiagnosticOverallResult.limitedCompatibility,
      overallSummary: json['overallSummary']?.toString() ?? '',
      lifecycleStatus: json['lifecycleStatus']?.toString() ?? DiagnosticLifecycleStatus.completed,
      categories: catMap,
      consentGiven: json['consentGiven'] == true,
      consentTimestamp: (json['consentTimestamp'] as num?)?.toInt(),
      adminNotes: json['adminNotes']?.toString(),
      reviewHistory: (json['reviewHistory'] as List<dynamic>? ?? [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList(),
      createdAt: (json['createdAt'] as num?)?.toInt(),
      updatedAt: (json['updatedAt'] as num?)?.toInt(),
    );
  }

  String toJsonString({bool pretty = false}) {
    if (pretty) {
      return const JsonEncoder.withIndent('  ').convert(toJson());
    }
    return jsonEncode(toJson());
  }
}

