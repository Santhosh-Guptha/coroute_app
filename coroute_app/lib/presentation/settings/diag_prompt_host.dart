import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/diag_log_service.dart';
import '../../domain/diag/diag_log.dart';

/// 3.55 diagnostics log: two gentle, optional questions, never during a ride.
///  * After a ride with an SOS, crash alarm or false-alarm cancel: "Help us improve safety: send the
///    log of this ride?" (skipped when "Send safety logs automatically" is on: then it is sent).
///  * When CoRoute support asked for this phone's log (admin "Ask for logs").
/// One tap sends; "Not now" forgets it. Placed once in MaterialApp.builder.
class DiagPromptHost extends StatefulWidget {
  final Widget child;
  final GlobalKey<NavigatorState> navigatorKey;
  const DiagPromptHost({super.key, required this.child, required this.navigatorKey});

  static const String safetyTitle = 'Help us improve safety';
  static const String safetyBody =
      'Send the app log of this ride to CoRoute? It shows what the phone saw and did (alerts, sensors, connection). No messages, names or numbers.';
  static const String requestTitle = 'CoRoute support asked for your app log';
  static const String requestBody = 'It helps them find the problem you reported. No messages, names or numbers. Nothing is sent unless you tap Send.';

  @override
  State<DiagPromptHost> createState() => _DiagPromptHostState();
}

class _DiagPromptHostState extends State<DiagPromptHost> {
  final DiagLogService _svc = DiagLogService.instance;
  bool _showing = false;
  // Asked once per app run (a failed send is not asked again at once; the Diagnostics screen can).
  final Set<String> _askedRequests = {};
  bool _askedSafety = false;

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onChange);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onChange());
  }

  @override
  void dispose() {
    _svc.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (_svc.safetyPrompt == null) _askedSafety = false; // answered: a later ride may ask again
    if (_showing || !mounted || DiagLog.rideId != null) return;
    bool wantRequest() => _svc.pendingRequestId != null && !_askedRequests.contains(_svc.pendingRequestId);
    bool wantSafety() => _svc.safetyPrompt != null && !_askedSafety;
    if (!wantRequest() && !wantSafety()) return;
    // Let the ride-end screens settle first.
    Future<void>.delayed(const Duration(seconds: 3), () {
      if (!mounted || _showing || DiagLog.rideId != null) return;
      if (wantRequest()) {
        _askedRequests.add(_svc.pendingRequestId!);
        _ask(request: true);
      } else if (wantSafety()) {
        _askedSafety = true;
        _ask(request: false);
      }
    });
  }

  Future<void> _ask({required bool request}) async {
    final ctx = widget.navigatorKey.currentContext;
    if (ctx == null) return;
    _showing = true;
    final send = await showAppSheet<bool>(
      ctx,
      title: request ? DiagPromptHost.requestTitle : DiagPromptHost.safetyTitle,
      builder: (c) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(request ? DiagPromptHost.requestBody : DiagPromptHost.safetyBody, style: AppText.body.copyWith(color: AppTheme.text2)),
          const SizedBox(height: Space.s24),
          DsButton(key: const ValueKey('diag_prompt_send'), label: 'Send', icon: Icons.send_rounded, onPressed: () => Navigator.of(c).pop(true)),
          const SizedBox(height: Space.s12),
          DsButton(key: const ValueKey('diag_prompt_later'), label: 'Not now', tone: DsButtonTone.outline, onPressed: () => Navigator.of(c).pop(false)),
        ],
      ),
    );
    _showing = false;
    if (send == true) {
      final err = request ? await _svc.sendAdminRequest() : await _svc.sendSafetyMoment();
      final m = widget.navigatorKey.currentContext;
      if (m != null && m.mounted) {
        ScaffoldMessenger.maybeOf(m)?.showSnackBar(SnackBar(content: Text(err ?? 'Log sent. Thank you!')));
      }
    } else {
      request ? _svc.dismissAdminRequest() : _svc.dismissSafetyPrompt();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
