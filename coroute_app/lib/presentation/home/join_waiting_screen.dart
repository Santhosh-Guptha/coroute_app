import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/rider_model.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/realtime_service.dart';

/// v3.60 join approval: shown after a code join answered "waiting for the host". It asks again every few seconds
/// (and at once when the host's answer arrives over the socket). Pops `true` when I am in the ride.
class JoinWaitingScreen extends StatefulWidget {
  final String code;
  final RiderModel rider;
  final String rideName;
  const JoinWaitingScreen({super.key, required this.code, required this.rider, this.rideName = ''});

  static Future<bool> open(BuildContext context, {required String code, required RiderModel rider, String rideName = ''}) async {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => JoinWaitingScreen(code: code, rider: rider, rideName: rideName)));
    return ok == true;
  }

  @override
  State<JoinWaitingScreen> createState() => _JoinWaitingScreenState();
}

class _JoinWaitingScreenState extends State<JoinWaitingScreen> {
  Timer? _timer;
  StreamSubscription<Map<String, dynamic>>? _sub;
  bool _asking = false;
  String? _declined;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 6), (_) => _ask());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sub = context.read<RealtimeService?>()?.events.listen((e) {
        final t = e['type']?.toString();
        if (t == 'JOIN_APPROVED') _ask();
        if (t == 'JOIN_DECLINED' && mounted) setState(() => _declined = 'The host did not let you in this time.');
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _ask() async {
    if (_asking || _declined != null || !mounted) return;
    _asking = true;
    final svc = context.read<ConvoyService>();
    final joined = await svc.joinConvoyByCode(code: widget.code, rider: widget.rider);
    _asking = false;
    if (!mounted) return;
    if (joined != null) {
      _timer?.cancel();
      AppHaptics.medium();
      Navigator.of(context).pop(true);
    } else if (svc.pendingJoin == null) {
      _timer?.cancel();
      setState(() => _declined = svc.lastError ?? 'The host did not let you in this time.');
    }
  }

  void _cancel() {
    context.read<ConvoyService>().clearPendingJoin();
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final declined = _declined;
    final name = widget.rideName.trim();
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) context.read<ConvoyService>().clearPendingJoin();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Join a ride')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(declined == null ? Icons.hourglass_top_rounded : Icons.block_rounded, size: 56, color: declined == null ? AppTheme.accentText : AppTheme.warnText),
                const SizedBox(height: 20),
                Text(
                  declined == null ? 'Waiting for the host' : 'Not let in',
                  key: const Key('join_waiting_title'),
                  textAlign: TextAlign.center,
                  style: AppText.title.copyWith(fontSize: 22),
                ),
                const SizedBox(height: 8),
                Text(
                  declined ?? (name.isEmpty ? 'The host will let you in shortly. Keep this screen open.' : 'The host of $name will let you in shortly. Keep this screen open.'),
                  textAlign: TextAlign.center,
                  style: AppText.body.copyWith(color: AppTheme.text2),
                ),
                if (declined == null) ...[
                  const SizedBox(height: 28),
                  const Center(child: SizedBox(width: 32, height: 32, child: CircularProgressIndicator(strokeWidth: 3))),
                ],
                const Spacer(),
                DsButton(
                  key: const Key('join_waiting_cancel'),
                  label: declined == null ? 'Cancel' : 'Close',
                  tone: DsButtonTone.outline,
                  onPressed: _cancel,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
