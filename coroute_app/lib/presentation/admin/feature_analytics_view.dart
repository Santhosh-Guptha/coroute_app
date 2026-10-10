import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/realtime_service.dart';

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
    return ListView(
      padding: const EdgeInsets.all(Space.s16),
      children: [
        Text(
          fresh ? 'Live feature analytics' : 'Analytics stale or offline',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const Text(
          'Operational counts for this gateway process; reset on server restart. Live ride counts come from the existing fleet feed. No private fuel amounts, contacts or Guardian links are shown.',
        ),
        if (stamp != null)
          Text(
            'Updated ${DateTime.fromMillisecondsSinceEpoch(stamp).toLocal()}',
          ),
        if (_error != null) Text(_error!),
        TextButton(onPressed: _load, child: const Text('Refresh analytics')),
        for (final row in (_data?['features'] as List? ?? []).whereType<Map>())
          Card(
            child: ListTile(
              title: Text(row['feature'].toString()),
              subtitle: Text(
                row['measured'] == true
                    ? '${row['requests']} operations · ${row['succeeded']} successful · ${row['failed']} failed · ${row['averageMs']} ms average'
                    : 'No observations since this server started',
              ),
            ),
          ),
        const SizedBox(height: Space.s16),
        Text(
          _fleetReceived
              ? 'Live rides (${_rides.length})'
              : 'Waiting for live ride data',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        for (final ride in _rides)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Space.s12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(ride['name']?.toString() ?? 'Ride'),
                  for (final entry
                      in ((ride['featureAnalytics'] as Map?)?['features']
                                  as Map? ??
                              {})
                          .entries)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _label(entry.key.toString()),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        if (entry.value is Map)
                          for (final metric in (entry.value as Map).entries)
                            Text(
                              '${_label(metric.key.toString())}: ${metric.value is bool ? (metric.value == true ? 'Yes' : 'No') : metric.value}',
                            ),
                      ],
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
