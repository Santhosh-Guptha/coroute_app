import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/realtime_service.dart';
import 'admin_ui.dart';

/// Uses the existing authenticated admin socket; no new connection or GPS stream.
class FeatureAnalyticsView extends StatefulWidget {
  const FeatureAnalyticsView({super.key});
  @override
  State<FeatureAnalyticsView> createState() => _FeatureAnalyticsViewState();
}

class _FeatureAnalyticsViewState extends State<FeatureAnalyticsView> {
  StreamSubscription<Map<String, dynamic>>? _sub;
  Map<String, dynamic>? _data;
  List<Map<String, dynamic>> _rides = [];
  String? _error;
  Timer? _age;
  late final ApiClient _api;
  String? _credential;
  int _revision = 0;
  bool _fleetReceived = false;
  @override
  void initState() {
    super.initState();
    _api = context.read<ApiClient>();
    _credential = _api.token;
    _api.addListener(_authChanged);
    final rt = context.read<RealtimeService?>();
    _sub = rt?.events.listen((event) {
      if (!mounted || event['type'] != 'FLEET') return;
      _revision++;
      setState(() {
        _fleetReceived = true;
        if (event['featureAnalytics'] is Map) {
          _data = Map<String, dynamic>.from(event['featureAnalytics']);
        }
        _rides = (event['convoys'] as List? ?? [])
            .whereType<Map>()
            .map((v) => Map<String, dynamic>.from(v))
            .toList();
        _error = null;
      });
    });
    _load();
    _age = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() {});
    });
  }

  void _authChanged() {
    if (!mounted || _credential == _api.token) return;
    _credential = _api.token;
    _revision++;
    setState(() {
      _data = null;
      _rides = [];
      _fleetReceived = false;
      _error = null;
    });
  }

  Future<void> _load() async {
    final api = context.read<ApiClient>();
    final token = api.token;
    final revision = ++_revision;
    try {
      final data = await api.get('/admin/feature-analytics');
      if (mounted &&
          revision == _revision &&
          api.token == token &&
          data is Map) {
        setState(() {
          _data = Map<String, dynamic>.from(data);
          _error = null;
        });
      }
    } catch (e) {
      if (!mounted || revision != _revision || api.token != token) return;
      setState(() {
        if (e is ApiException && (e.statusCode == 401 || e.statusCode == 403)) {
          _data = null;
          _rides = [];
          _fleetReceived = false;
        }
        _error = 'Analytics unavailable. Retry when connected.';
      });
    }
  }

  @override
  void dispose() {
    _api.removeListener(_authChanged);
    _sub?.cancel();
    _age?.cancel();
    super.dispose();
  }

  String _label(String key) {
    final text = key.replaceAllMapped(
      RegExp(r'([a-z])([A-Z])'),
      (m) => '${m[1]} ${m[2]}',
    );
    return text.isEmpty ? text : '${text[0].toUpperCase()}${text.substring(1)}';
  }

  @override
  Widget build(BuildContext context) {
    final online = context.watch<RealtimeService?>()?.isConnected == true;
    final stamp = (_data?['generatedAt'] as num?)?.toInt();
    final age = stamp == null
        ? null
        : DateTime.now().millisecondsSinceEpoch - stamp;
    final fresh = online && age != null && age >= 0 && age < 45000;
    final features = (_data?['features'] as List? ?? []).whereType<Map>().toList();
    final error = _error;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      children: [
        DsCard(
          tinted: fresh,
          borderColor: fresh ? AppTheme.tint : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(fresh ? Icons.sensors_rounded : Icons.sensors_off_rounded, size: 22, color: fresh ? AppTheme.accentText : AppTheme.warnText),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      fresh ? 'Live feature analytics' : 'Analytics stale or offline',
                      style: AppText.title.copyWith(color: fresh ? AppTheme.accentText : AppTheme.text),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Operational counts for this gateway process; reset on server restart. Live ride counts come from the existing fleet feed. No private fuel amounts, contacts or Guardian links are shown.',
                style: AppText.label,
              ),
              if (stamp != null) ...[
                const SizedBox(height: 6),
                Text(
                  'Updated ${DateTime.fromMillisecondsSinceEpoch(stamp).toLocal()}',
                  style: AppText.caption.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
              if (error != null) ...[
                const SizedBox(height: 8),
                StatusLine(icon: Icons.cloud_off_rounded, text: error, color: AppTheme.warnText),
              ],
              const SizedBox(height: 12),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: SizedBox(
                  width: 220,
                  child: DsButton(
                    label: 'Refresh analytics',
                    icon: Icons.refresh_rounded,
                    tone: DsButtonTone.outline,
                    height: 44,
                    fontSize: 14,
                    onPressed: _load,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (features.isNotEmpty) ...[
          const AdminSectionLabel('Features'),
          AdminTable(
            columns: const ['Feature', 'Activity'],
            rows: [
              for (var i = 0; i < features.length; i++)
                AdminRow(
                  leading: AdminRowIcon(
                    features[i]['measured'] == true ? Icons.bolt_rounded : Icons.hourglass_empty_rounded,
                    color: features[i]['measured'] == true ? AppTheme.accentText : AppTheme.muted,
                  ),
                  title: features[i]['feature'].toString(),
                  detail: features[i]['measured'] == true
                      ? '${features[i]['requests']} operations · ${features[i]['succeeded']} successful · ${features[i]['failed']} failed · ${features[i]['averageMs']} ms average'
                      : 'No observations since this server started',
                  divider: i < features.length - 1,
                ),
            ],
          ),
        ],
        AdminSectionLabel(
          _fleetReceived
              ? 'Live rides (${_rides.length})'
              : 'Waiting for live ride data',
        ),
        for (final ride in _rides)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: DsCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const AdminRowIcon(Icons.two_wheeler_rounded),
                      const SizedBox(width: 12),
                      Expanded(child: Text(ride['name']?.toString() ?? 'Ride', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title)),
                    ],
                  ),
                  for (final entry
                      in ((ride['featureAnalytics'] as Map?)?['features']
                                  as Map? ??
                              {})
                          .entries)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          DsSectionHeader(_label(entry.key.toString())),
                          const SizedBox(height: 4),
                          if (entry.value is Map)
                            for (final metric in (entry.value as Map).entries)
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 2),
                                child: Text(
                                  '${_label(metric.key.toString())}: ${metric.value is bool ? (metric.value == true ? 'Yes' : 'No') : metric.value}',
                                  style: AppText.label.copyWith(color: AppTheme.text),
                                ),
                              ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
