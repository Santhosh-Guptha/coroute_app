import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/intel_care_service.dart';
import '../../data/services/safety_service.dart';
import '../rider/widgets/road_ahead_settings_card.dart'; // round 7: curve warnings and road speed limits
import 'private_places_card.dart';

/// Round 4 Settings > "Road safety" (docs/intelligence/ROAD_AND_SAFETY_INTELLIGENCE.md):
///  * "Help make roads safer" (opt-in, off by default, stored on the server with the time);
///  * Hazard warnings (on), Rough road ahead (on, low priority), Twisty section ahead (on), Long ride and night
///    nudges (on), break reminder interval (the 2 h reminder is always on);
///  * Download / Delete my contributions, with an honest note on what can be deleted.
class RoadSafetyScreen extends StatefulWidget {
  const RoadSafetyScreen({super.key});

  static const String title = 'Road safety';
  static const String consentTitle = 'Help make roads safer';
  static const String consentSubtitle = 'Share anonymous road and safety signals from your rides. Off by default.';
  static const String deleteNote =
      'Deleting removes everything from the last 90 days, including its share of the totals. Older contributions exist only inside anonymous totals that cannot be traced to you, so they cannot be split out.';

  @override
  State<RoadSafetyScreen> createState() => _RoadSafetyScreenState();
}

class _RoadSafetyScreenState extends State<RoadSafetyScreen> {
  IntelCareService? get _intel => SafetyService.hasInstance ? SafetyService.instance.intel : null;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final i = _intel;
    if (i != null) {
      i.addListener(_changed);
      i.load().then((_) => i.refreshConsent()).ignore();
    }
  }

  @override
  void dispose() {
    _intel?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _say(String m) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(m)));

  Future<void> _consent(bool on) async {
    final i = _intel;
    if (i == null || _busy) return;
    setState(() => _busy = true);
    final ok = await i.setConsent(on);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) _say('Could not save. Check your connection and try again.');
  }

  Future<void> _export() async {
    try {
      final r = await _intel?.exportContributions();
      final rows = r is Map && r['rows'] is List ? (r['rows'] as List).length : 0;
      await Clipboard.setData(ClipboardData(text: const JsonEncoder.withIndent('  ').convert(r)));
      _say('$rows contributions from the last 90 days copied to the clipboard.');
    } catch (_) {
      _say('Could not download. Try again later.');
    }
  }

  Future<void> _delete() async {
    final ok = await showAppDialog<bool>(
      context, // round 7: app motion (spring scale + fade, reduce-motion aware)
      builder: (c) => AlertDialog(
        title: const Text('Delete my contributions?'),
        content: const Text(RoadSafetyScreen.deleteNote),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(key: const ValueKey('road_safety_delete_confirm'), onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final msg = await _intel?.deleteContributions();
      _say(msg ?? 'Deleted.');
    } catch (_) {
      _say('Could not delete. Try again later.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = _intel;
    final s = i?.settings;
    Widget sw(String key, String title, String sub, bool v, ValueChanged<bool> on) => SwitchListTile(
          key: ValueKey(key),
          contentPadding: EdgeInsets.zero,
          title: Text(title, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
          subtitle: Text(sub, style: AppText.caption),
          value: v,
          onChanged: on,
        );
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: dsScreenPadding,
              children: [
                DsScreenHeader(title: RoadSafetyScreen.title, onBack: () => Navigator.maybePop(context)),
                if (i == null || s == null)
                  const Padding(padding: EdgeInsets.all(24), child: Text('Road safety settings are not available right now.'))
                else ...[
                  const SizedBox(height: Space.s12),
                  DsSectionHeader(RoadSafetyScreen.consentTitle),
                  const SizedBox(height: Space.s8),
                  DsCard(
                    padding: const EdgeInsets.symmetric(horizontal: Space.s16, vertical: Space.s8),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      sw('road_safety_consent', RoadSafetyScreen.consentTitle, RoadSafetyScreen.consentSubtitle, s.consentOn, _busy ? (_) {} : _consent),
                      Text(
                        'Never your route, name, phone number or medical details. The first and last 300 m of every ride are left out. A spot is shown only once 5 different riders passed. Raw signals are deleted after 90 days. Everyone gets the warnings either way.',
                        style: AppText.caption.copyWith(color: AppTheme.text2),
                      ),
                      const SizedBox(height: Space.s8),
                      Wrap(spacing: 8, children: [
                        TextButton(key: const ValueKey('road_safety_export'), onPressed: _export, child: const Text('Download my contributions')),
                        TextButton(key: const ValueKey('road_safety_delete'), onPressed: _delete, child: const Text('Delete my contributions')),
                      ]),
                    ]),
                  ),
                  const SizedBox(height: Space.s24),
                  // 3.56 (round 6): places the rider's rides are hidden near (kept on the phone only).
                  const DsSectionHeader(PrivatePlacesCard.title),
                  const SizedBox(height: Space.s8),
                  const PrivatePlacesCard(),
                  const SizedBox(height: Space.s24),
                  const DsSectionHeader('Warnings while riding'),
                  const SizedBox(height: Space.s8),
                  DsCard(
                    padding: const EdgeInsets.symmetric(horizontal: Space.s16, vertical: Space.s8),
                    child: Column(children: [
                      sw('road_safety_hazards', 'Hazard warnings', 'A gentle "Hazard ahead" before spots where many riders braked hard or crashed', s.hazardWarnings,
                          (v) => i.update((x) => x.hazardWarnings = v)),
                      sw('road_safety_rough', 'Rough road ahead', 'Before potholes and rough stretches, at most once every 5 km', s.roughRoadWarnings,
                          (v) => i.update((x) => x.roughRoadWarnings = v)),
                      sw('road_safety_twisty', 'Twisty section ahead', 'Before twisty roads and ghats on your route: slow down', s.twistyWarnings,
                          (v) => i.update((x) => x.twistyWarnings = v)),
                      sw('road_safety_nudges', 'Long ride and night nudges', 'A stronger nudge after 4 hours, and a notice when riding between 23:00 and 05:00', s.longRideNudges,
                          (v) => i.update((x) => x.longRideNudges = v)),
                      ListTile(
                        key: const ValueKey('road_safety_interval'),
                        contentPadding: EdgeInsets.zero,
                        title: Text('Break reminder', style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
                        subtitle: Text(
                            s.breakIntervalMin < 120 ? 'Every ${_hm(s.breakIntervalMin)} without a 10-minute stop' : 'Every 2 h without a 10-minute stop (always on)',
                            style: AppText.caption),
                        trailing: DropdownButton<int>(
                          value: s.breakIntervalMin < 120 ? s.breakIntervalMin : 120,
                          items: const [
                            DropdownMenuItem(value: 90, child: Text('1 h 30')),
                            DropdownMenuItem(value: 105, child: Text('1 h 45')),
                            DropdownMenuItem(value: 120, child: Text('2 h')),
                          ],
                          onChanged: (v) => i.update((x) => x.breakIntervalMin = v ?? 120),
                        ),
                      ),
                      if (kDebugMode)
                        ListTile(
                          key: const ValueKey('road_safety_debug_interval'),
                          contentPadding: EdgeInsets.zero,
                          title: const Text('QA: short break interval'),
                          subtitle: Text(s.debugBreakMin == 0 ? 'Off' : '${s.debugBreakMin} min (debug builds only)'),
                          trailing: DropdownButton<int>(
                            value: s.debugBreakMin,
                            items: const [
                              DropdownMenuItem(value: 0, child: Text('Off')),
                              DropdownMenuItem(value: 2, child: Text('2 min')),
                              DropdownMenuItem(value: 5, child: Text('5 min')),
                            ],
                            onChanged: (v) => i.update((x) => x.debugBreakMin = v ?? 0),
                          ),
                        ),
                    ]),
                  ),
                  // Round 7: curve warnings, road speed limits, estimated limits, road data storage.
                  const SizedBox(height: Space.s24),
                  const DsSectionHeader(RoadAheadSettingsCard.title),
                  const SizedBox(height: Space.s8),
                  const DsCard(
                    padding: EdgeInsets.symmetric(horizontal: Space.s16, vertical: Space.s8),
                    child: RoadAheadSettingsCard(),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _hm(int min) => min % 60 == 0 ? '${min ~/ 60} h' : '${min ~/ 60} h ${min % 60} min';
}
