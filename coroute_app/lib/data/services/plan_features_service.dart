import 'package:flutter/widgets.dart';

import 'api_client.dart';

/// v3.60 features and limits by plan (gateway/src/plans.js, set by the admin). The app hides a button the plan
/// does not include; the gateway enforces it anyway (403 PLAN_FEATURE). Safety is never in this list.
/// Unknown (not loaded yet, older gateway): everything on, limits as before.
class PlanFeaturesService extends ChangeNotifier {
  PlanFeaturesService(this._api, {bool autoStart = true}) {
    if (autoStart) {
      _api.addListener(_onApi);
      if (_api.hasToken) refresh();
    }
  }

  final ApiClient _api;
  bool _hadToken = false;
  bool _disposed = false;
  String _planId = 'community';
  String _planName = '';
  Map<String, bool> _features = const {};
  Map<String, int> _limits = const {};

  String get planId => _planId;
  String get planName => _planName;
  bool has(String featureId) => _features[featureId] ?? true;
  int limit(String id, int fallback) => _limits[id] ?? fallback;

  /// Communities chat only up to this many members (default 50).
  int get chatMembersMax => limit('chatMembersMax', 50);

  void _onApi() {
    final has = _api.hasToken;
    if (has && !_hadToken) refresh();
    _hadToken = has;
  }

  Future<void> refresh() async {
    if (_disposed || !_api.hasToken) return;
    try {
      final res = await _api.get('/me/plan-features');
      if (res is! Map) return;
      _planId = res['planId']?.toString() ?? _planId;
      _planName = res['planName']?.toString() ?? '';
      final f = res['features'];
      final l = res['limits'];
      _features = f is Map ? {for (final e in f.entries) e.key.toString(): e.value != false} : const {};
      _limits = l is Map ? {for (final e in l.entries) if (e.value is num) e.key.toString(): (e.value as num).toInt()} : const {};
      if (!_disposed) notifyListeners();
    } catch (_) {
      // Older gateway or offline: keep the defaults (everything on).
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _api.removeListener(_onApi);
    super.dispose();
  }
}
