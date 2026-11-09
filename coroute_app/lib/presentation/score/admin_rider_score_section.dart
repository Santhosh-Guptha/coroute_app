import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../domain/score/rider_score.dart';
import 'rider_score_card.dart';

/// 3.55 admin user detail: the rider score breakdown (`riderScore` of GET /admin/users/:id/details).
/// Numbers only: score, components, totals and the last rides' per-ride parts (no places).
class AdminRiderScoreSection extends StatelessWidget {
  final Map<String, dynamic>? data;
  const AdminRiderScoreSection({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final d = data;
    if (d == null) {
      return DsCard(child: Text('No rides recorded for the rider score yet.', style: AppText.body.copyWith(color: AppTheme.text2)));
    }
    final s = RiderScore.fromJson(d);
    final totals = d['totals'] is Map ? Map<String, dynamic>.from(d['totals'] as Map) : const <String, dynamic>{};
    final rides = d['recentRides'] is List ? (d['recentRides'] as List).whereType<Map>().toList() : const <Map>[];
    final fmt = DateFormat('d MMM yyyy');
    String n(Object? v) => v is num ? (v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1)) : '–';
    return DsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ScoreRing(score: s.score, size: 56, stroke: 6),
              const SizedBox(width: Space.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.ready ? (s.level ?? '') : 'Not ready (${s.ridesCounted} of ${s.minRides} rides)', style: AppText.title),
                    Text(
                      'Total ${n(totals['km'])} km · ${n(totals['hours'])} h · ${n(totals['rides'])} rides · longest ${n(totals['longestKm'])} km',
                      style: AppText.caption,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.s8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final c in ScoreComponent.values) DsChip('${c.title}: ${s.component(c) ?? '–'}'),
            ],
          ),
          if (rides.isNotEmpty) ...[
            const SizedBox(height: Space.s12),
            Text('Recent rides (speed / smoothness / safety)', style: AppText.caption.copyWith(fontWeight: FontWeight.w700)),
            for (final r in rides.take(10))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(
                  '${r['endedAt'] is num ? fmt.format(DateTime.fromMillisecondsSinceEpoch((r['endedAt'] as num).toInt())) : ''}'
                  ' · ${n(r['km'])} km · ${n(r['speed'])} / ${n(r['smoothness'])} / ${n(r['safety'])}'
                  '${(r['overspeedEpisodes'] as num? ?? 0) > 0 ? ' · over limit ${r['overspeedEpisodes']}x' : ''}'
                  '${(r['separated'] as num? ?? 0) > 0 ? ' · separated ${r['separated']}x' : ''}',
                  style: AppText.label,
                ),
              ),
          ],
        ],
      ),
    );
  }
}
