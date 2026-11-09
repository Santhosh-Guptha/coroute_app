import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/rider_score_service.dart';
import '../../domain/score/rider_score.dart';
import '../widgets/feature_switch.dart';
import 'rider_score_screen.dart';

/// 3.55 "Your rider score" card for the profile screen (owned by the profile; embed with
/// `const RiderScoreCard()`). Shows the score ring and level, or how many rides are still needed,
/// and opens [RiderScoreScreen]. Hides itself when the admin switch `riderScore` is off.
class RiderScoreCard extends StatefulWidget {
  const RiderScoreCard({super.key});

  @override
  State<RiderScoreCard> createState() => _RiderScoreCardState();
}

class _RiderScoreCardState extends State<RiderScoreCard> {
  RiderScoreService? _svc;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final api = context.read<ApiClient?>();
      if (api == null) return;
      final svc = RiderScoreService(api);
      setState(() => _svc = svc);
      svc.refresh();
    });
  }

  @override
  void dispose() {
    _svc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!context.featureOn('riderScore')) return const SizedBox.shrink();
    final svc = _svc;
    if (svc == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: svc,
      builder: (context, _) {
        final s = svc.score;
        if (s != null && !s.enabled) return const SizedBox.shrink();
        return DsCard(
          key: const Key('rider_score_card'),
          semanticsLabel: s?.ready == true ? 'Your rider score ${s!.score} of 100, ${s.level}' : 'Your rider score',
          onTap: () async {
            await RiderScoreScreen.open(context);
            if (mounted) svc.loadScore();
          },
          child: Row(
            children: [
              ScoreRing(score: s?.score, size: 64, stroke: 7),
              const SizedBox(width: Space.s16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Your rider score', style: AppText.title),
                    const SizedBox(height: 2),
                    Text(
                      s == null
                          ? (svc.error ?? 'Loading…')
                          : s.ready
                              ? '${s.level ?? ''} · tap for tips'
                              : (s.progressLine ?? ''),
                      style: AppText.label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
            ],
          ),
        );
      },
    );
  }
}

/// Colour of a score / component value (never red for "no data").
Color scoreColor(int? v) {
  if (v == null) return AppTheme.muted;
  if (v >= 70) return StatusColors.success;
  if (v >= 50) return StatusColors.warning;
  return AppTheme.warnText;
}

/// The score ring: an arc for 0-100 with the number in the middle ("–" before the score is ready).
class ScoreRing extends StatelessWidget {
  final int? score;
  final double size;
  final double stroke;
  const ScoreRing({super.key, required this.score, this.size = 140, this.stroke = 12});

  @override
  Widget build(BuildContext context) {
    final v = score;
    return Semantics(
      label: v == null ? 'No score yet' : 'Score $v of 100',
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _RingPainter(value: (v ?? 0) / 100, color: scoreColor(v), track: AppTheme.map, stroke: stroke),
          child: Center(
            child: Text(
              v == null ? '–' : '$v',
              style: AppText.metric.copyWith(fontSize: size * 0.34, color: AppTheme.text),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double value;
  final Color color;
  final Color track;
  final double stroke;
  _RingPainter({required this.value, required this.color, required this.track, required this.stroke});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset(stroke / 2, stroke / 2) & Size(size.width - stroke, size.height - stroke);
    final base = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawArc(rect, 0, math.pi * 2, false, base);
    if (value <= 0) return;
    final arc = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = stroke;
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * value.clamp(0.0, 1.0), false, arc);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.value != value || old.color != color || old.track != track || old.stroke != stroke;
}

/// One component row: title, value bar and the plain explanation.
class ScoreComponentRow extends StatelessWidget {
  final ScoreComponent component;
  final int? value;
  final bool divider;
  const ScoreComponentRow({super.key, required this.component, required this.value, this.divider = true});

  @override
  Widget build(BuildContext context) {
    final v = value;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: Space.s12),
      decoration: BoxDecoration(border: divider ? Border(bottom: BorderSide(color: AppTheme.border)) : null),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(component.title, style: AppText.body.copyWith(fontWeight: FontWeight.w800))),
              Text(v == null ? '–' : '$v', style: AppText.title.copyWith(color: scoreColor(v))),
            ],
          ),
          const SizedBox(height: Space.s8),
          DsProgressBar(value: (v ?? 0) / 100, color: scoreColor(v), height: 10),
          const SizedBox(height: Space.s8),
          Text(component.verdict(v), style: AppText.label.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text('${component.explanation} (${component.weight}% of your score)', style: AppText.caption),
        ],
      ),
    );
  }
}
