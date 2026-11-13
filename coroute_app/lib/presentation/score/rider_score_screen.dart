import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/rider_score_service.dart';
import '../../domain/score/rider_score.dart';
import '../widgets/feature_switch.dart';
import 'leaderboard_screen.dart';
import 'rider_score_card.dart';

/// 3.55 "Your rider score": the score ring and level, the four components with plain explanations,
/// tips, the setting "Use my ride safety report for my rider score" and a way to the leaderboard.
class RiderScoreScreen extends StatefulWidget {
  const RiderScoreScreen({super.key});

  static const String title = 'Your rider score';
  static const String privacyLine = 'Only you can see your score. The leaderboard shows usernames only.';
  /// Always on since Nov 11 (owner decision): a plain line, no switch.
  static const String useReportLabel = 'Your score uses your ride safety report';
  static const String useReportSubtitle =
      'Only counts per ride (hard brakes, breaks, tiredness, minutes over the limit). Never your route or position.';

  static Future<void> open(BuildContext context) async {
    if (!context.featureOnNow('riderScore')) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('The rider score is turned off for now.')));
      return;
    }
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const RiderScoreScreen()));
  }

  @override
  State<RiderScoreScreen> createState() => _RiderScoreScreenState();
}

class _RiderScoreScreenState extends State<RiderScoreScreen> {
  late final RiderScoreService _svc = RiderScoreService(context.read<ApiClient>());

  @override
  void initState() {
    super.initState();
    // Round 7 (stale-while-revalidate): the last score is on screen at once; a fresh one replaces it.
    _svc.score = SwrCache.shared.peek<RiderScore>('score:me');
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _svc.refresh();
      final s = _svc.score;
      if (s != null && _svc.error == null) SwrCache.shared.put<RiderScore>('score:me', s);
    });
  }

  @override
  void dispose() {
    _svc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final leaderboardOn = context.featureOn('leaderboard');
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                  child: DsScreenHeader(
                    title: RiderScoreScreen.title,
                    subtitle: 'How safely you ride, 0 to 100',
                    onBack: () => Navigator.maybePop(context),
                    trailing: leaderboardOn
                        ? DsRoundButton(
                            key: const Key('score_open_leaderboard'),
                            icon: Icons.emoji_events_rounded,
                            label: 'Leaderboard',
                            onTap: () => LeaderboardScreen.open(context),
                            size: 48,
                          )
                        : null,
                  ),
                ),
                Expanded(
                  child: ListenableBuilder(
                    listenable: _svc,
                    builder: (context, _) => RefreshIndicator(
                      color: AppTheme.accentText,
                      onRefresh: _svc.refresh,
                      child: _body(leaderboardOn),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(bool leaderboardOn) {
    final s = _svc.score;
    if (s == null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
        children: [
          const SizedBox(height: Space.s32),
          if (_svc.error != null)
            EmptyState(icon: Icons.cloud_off_rounded, title: 'Score not loaded', message: _svc.error, primaryLabel: 'Try again', onPrimary: _svc.refresh)
          else
            const SkeletonCards(count: 3, stats: true), // round 7: score cards
        ],
      );
    }
    if (!s.enabled) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
        children: const [
          SizedBox(height: Space.s32),
          EmptyState(icon: Icons.speed_rounded, title: 'Turned off for now', message: 'The rider score is turned off for now.'),
        ],
      );
    }
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      children: [
        DsCard(
          child: Column(
            children: [
              ScoreRing(score: s.score),
              const SizedBox(height: Space.s12),
              Text(s.ready ? (s.level ?? '') : 'Not ready yet', style: AppText.headline, textAlign: TextAlign.center),
              const SizedBox(height: Space.s4),
              Text(s.ready ? levelDescription(s.level) : (s.progressLine ?? ''), style: AppText.label, textAlign: TextAlign.center),
              const SizedBox(height: Space.s8),
              Text(
                '${s.ridesCounted} ${s.ridesCounted == 1 ? 'ride' : 'rides'} counted',
                style: AppText.caption,
              ),
            ],
          ),
        ),
        if (s.tips.isNotEmpty) ...[
          const SizedBox(height: Space.s24),
          const DsSectionHeader('Tips'),
          const SizedBox(height: Space.s8),
          DsCard(
            tinted: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final t in s.tips)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.lightbulb_outline_rounded, size: 20, color: AppTheme.accentText),
                        const SizedBox(width: Space.s8),
                        Expanded(child: Text(t, style: AppText.body)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: Space.s24),
        const DsSectionHeader('What makes your score'),
        const SizedBox(height: Space.s8),
        DsCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(
            children: [
              for (final c in ScoreComponent.values)
                ScoreComponentRow(component: c, value: s.component(c), divider: c != ScoreComponent.values.last),
            ],
          ),
        ),
        const SizedBox(height: Space.s24),
        DsCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Padding(
            key: const Key('score_use_safety_report'),
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.insights_rounded, size: 22, color: AppTheme.accentText),
                const SizedBox(width: Space.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(RiderScoreScreen.useReportLabel, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                      Text(RiderScoreScreen.useReportSubtitle, style: AppText.caption),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (leaderboardOn) ...[
          const SizedBox(height: Space.s16),
          DsButton(
            key: const Key('score_leaderboard_button'),
            label: 'See the leaderboard',
            icon: Icons.emoji_events_rounded,
            onPressed: () => LeaderboardScreen.open(context),
          ),
        ],
        const SizedBox(height: Space.s16),
        Text(
          '${RiderScoreScreen.privacyLine} Speed is never rewarded, and using SOS never lowers your score.',
          textAlign: TextAlign.center,
          style: AppText.caption,
        ),
      ],
    );
  }
}
