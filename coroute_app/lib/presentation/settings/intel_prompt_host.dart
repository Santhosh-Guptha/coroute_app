import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/intel_care_service.dart';
import '../../data/services/safety_service.dart';
import '../../domain/intel/intel_policies.dart';

/// Round 4 road & safety intelligence prompts, never during a ride or an SOS / crash alarm:
///  * once, after the first completed ride: "Help make roads safer?" (opt-in; "Not now" is remembered);
///  * after a cancelled crash alarm: "Was this a real crash?" (optional, one tap; labels the crash brain's data).
/// Placed once in MaterialApp.builder (inside the crash alarm host, so it can never cover the alarm).
class IntelPromptHost extends StatefulWidget {
  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;
  const IntelPromptHost({super.key, required this.child, required this.navigatorKey});

  @override
  State<IntelPromptHost> createState() => _IntelPromptHostState();
}

class _IntelPromptHostState extends State<IntelPromptHost> {
  IntelCareService? _intel;
  SafetyService? _safety;
  bool _showing = false;
  Timer? _retry;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _attach());
  }

  void _attach() {
    if (!mounted || !SafetyService.hasInstance) {
      _retry = Timer(const Duration(seconds: 5), _attach);
      return;
    }
    _safety = SafetyService.instance;
    _intel = _safety!.intel..addListener(_onChange);
    _safety!.addListener(_onChange);
  }

  @override
  void dispose() {
    _retry?.cancel();
    _intel?.removeListener(_onChange);
    _safety?.removeListener(_onChange);
    super.dispose();
  }

  bool get _busy => (_safety?.rideOn ?? true) || _safety?.alarm != null;

  void _onChange() {
    final i = _intel;
    if (i == null || _showing || !mounted || _busy) return;
    final feedback = i.feedbackAsk != null;
    final consent = i.shouldPromptConsent(riding: false);
    if (!feedback && !consent) return;
    // Let the ride-end and alarm screens settle first.
    Future<void>.delayed(const Duration(seconds: 4), () {
      if (!mounted || _showing || _busy) return;
      if (i.feedbackAsk != null) {
        _askFeedback(i);
      } else if (i.shouldPromptConsent(riding: false)) {
        _askConsent(i);
      }
    });
  }

  Future<void> _askConsent(IntelCareService i) async {
    final ctx = widget.navigatorKey.currentContext;
    if (ctx == null) return;
    _showing = true;
    final yes = await showAppSheet<bool>(
      ctx,
      title: ConsentPromptPolicy.title,
      builder: (c) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(ConsentPromptPolicy.body, style: AppText.body.copyWith(color: AppTheme.text2)),
          const SizedBox(height: Space.s24),
          DsButton(key: const ValueKey('intel_consent_yes'), label: 'Yes, help make roads safer', icon: Icons.add_road_rounded, onPressed: () => Navigator.of(c).pop(true)),
          const SizedBox(height: Space.s8),
          TextButton(key: const ValueKey('intel_consent_later'), onPressed: () => Navigator.of(c).pop(false), child: const Text('Not now')),
          Text('You can change this any time in Settings, Road safety.', style: AppText.caption, textAlign: TextAlign.center),
        ],
      ),
    );
    if (yes == true) {
      await i.setConsent(true, fromPrompt: true);
    } else {
      await i.dismissPrompt();
    }
    _showing = false;
  }

  Future<void> _askFeedback(IntelCareService i) async {
    final ctx = widget.navigatorKey.currentContext;
    if (ctx == null) return;
    _showing = true;
    final real = await showAppSheet<bool>(
      ctx,
      title: CrashFeedbackAsk.title,
      builder: (c) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(CrashFeedbackAsk.body, style: AppText.body.copyWith(color: AppTheme.text2)),
          const SizedBox(height: Space.s24),
          DsButton(key: const ValueKey('crash_feedback_no'), label: 'No, a false alarm', onPressed: () => Navigator.of(c).pop(false)),
          const SizedBox(height: Space.s8),
          TextButton(key: const ValueKey('crash_feedback_yes'), onPressed: () => Navigator.of(c).pop(true), child: const Text('Yes, it was a real crash')),
        ],
      ),
    );
    i.answerCrashFeedback(real);
    _showing = false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
