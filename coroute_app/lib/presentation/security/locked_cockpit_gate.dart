import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/safety_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/app_lock_service.dart';
import '../../data/services/app_security_native.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/lock_screen_cockpit_service.dart';
import '../../data/services/safety_service.dart';
import '../../domain/security/lock_screen_cockpit_policy.dart';

/// Locked cockpit (docs/features_355/lock_screen_cockpit.md): while CoRoute is shown over a locked keyguard during
/// a ride, a small padlock chip says so ("Locked: unlock to open more"; tap for Unlock, Call 112 and Medical ID),
/// and a private screen opened from the cockpit is covered until the phone is unlocked.
///
/// Sits above the app lock gate in MaterialApp.builder. The two never show together: a ride keeps the app lock
/// away, and while the app lock screen shows (it offers SOS, Call 112 and Medical ID itself) this gate stays out
/// of the way.
class LockedCockpitGate extends StatelessWidget {
  const LockedCockpitGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<LockScreenCockpitService?>();
    if (svc == null) return child;
    final appLocked = context.select<AppLockService?, bool>((l) => l?.locked ?? false);
    final locked = svc.locked && !appLocked;
    final shield = locked && svc.guard.topIsPending;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => svc.noteTap(),
      child: Stack(
        children: [
          ExcludeSemantics(excluding: shield, child: AbsorbPointer(absorbing: shield, child: child)),
          if (shield) Positioned.fill(child: LockedShield(service: svc)),
          if (locked && !shield && !svc.aodShowing)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 4,
              left: 0,
              right: 0,
              child: Center(child: LockedChip(service: svc)),
            ),
        ],
      ),
    );
  }
}

/// Helpers for actions that are not screens (share, copy, calling a contact).
class LockedCockpit {
  LockedCockpit._();

  static LockScreenCockpitService? _of(BuildContext context) {
    try {
      return Provider.of<LockScreenCockpitService?>(context, listen: false);
    } catch (_) {
      return null;
    }
  }

  /// True while the cockpit is shown over a locked keyguard ([listen]: rebuild on change).
  static bool isLocked(BuildContext context, {bool listen = true}) {
    try {
      if (listen) return context.select<LockScreenCockpitService?, bool>((s) => s?.locked ?? false);
      return _of(context)?.locked ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Runs [run] now when [action] needs no unlock, else after the phone is unlocked (nothing when cancelled).
  static Future<bool> run(BuildContext context, CockpitAction action, FutureOr<void> Function() run) async {
    final svc = _of(context);
    if (svc == null) {
      await run();
      return true;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    final ok = await svc.runUnlocked(action, run);
    if (!ok) {
      messenger
        ?..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text(LockScreenCockpitPolicy.unlockFailed)));
    }
    return ok;
  }
}

/// 3.56 (round 6): every "Call" button of the ride screens goes through here. Not locked: dials at
/// once. Locked: emergency lines dial at once, the rider's own emergency contact dials at once while
/// the rider's own SOS / crash alarm is open, every other number asks for the phone's unlock first
/// ([LockScreenCockpitPolicy.callNeedsUnlock] explains why). True when [dial] ran.
Future<bool> callFromCockpit(BuildContext context, String number, FutureOr<void> Function() dial) async {
  var locked = false;
  try {
    locked = Provider.of<LockScreenCockpitService?>(context, listen: false)?.locked ?? false;
  } catch (_) {}
  if (!locked) {
    await dial();
    return true;
  }
  String? own;
  try {
    own = Provider.of<AuthService?>(context, listen: false)?.emergencyContact;
  } catch (_) {}
  final needs = LockScreenCockpitPolicy.callNeedsUnlock(
    locked: true,
    number: number,
    emergencyNumbers: SafetyConstants.emergencyNumbers,
    ownEmergencyContact: own,
    ownEmergencyOpen: SafetyService.hasInstance && SafetyService.instance.emergencyOpen,
  );
  if (!needs) {
    await dial();
    return true;
  }
  return LockedCockpit.run(context, CockpitAction.dialContact, dial);
}

/// The padlock chip; tapped, it opens Unlock, Call 112 and Medical ID.
class LockedChip extends StatefulWidget {
  const LockedChip({super.key, required this.service});

  final LockScreenCockpitService service;

  @override
  State<LockedChip> createState() => _LockedChipState();
}

class _LockedChipState extends State<LockedChip> {
  bool _open = false;

  Future<void> _unlock() async {
    final ok = await widget.service.requestUnlock();
    if (mounted && ok) setState(() => _open = false);
  }

  @override
  Widget build(BuildContext context) {
    final fg = AppTheme.text;
    return Material(
      type: MaterialType.transparency,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 150),
        child: Container(
          key: const Key('locked_cockpit_chip'),
          constraints: const BoxConstraints(maxWidth: 360),
          decoration: BoxDecoration(
            color: AppTheme.card.withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(_open ? 16 : 20),
            border: Border.all(color: AppTheme.border),
          ),
          child: _open ? _panel(fg) : _pill(fg),
        ),
      ),
    );
  }

  Widget _pill(Color fg) {
    return Semantics(
      button: true,
      label: LockScreenCockpitPolicy.chipText,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => setState(() => _open = true),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_rounded, size: 16, color: fg),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    LockScreenCockpitPolicy.chipText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.label.copyWith(color: fg, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _panel(Color fg) {
    final busy = widget.service.unlocking;
    return Padding(
      padding: const EdgeInsets.all(Space.s12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.lock_rounded, size: 18, color: fg),
              const SizedBox(width: 8),
              Expanded(child: Text(LockScreenCockpitPolicy.chipText, style: AppText.label.copyWith(color: fg, fontWeight: FontWeight.w600))),
              IconButton(
                key: const Key('locked_cockpit_chip_close'),
                tooltip: null,
                icon: Icon(Icons.close_rounded, color: fg),
                onPressed: () => setState(() => _open = false),
              ),
            ],
          ),
          const SizedBox(height: Space.s8),
          DsButton(
            key: const Key('locked_cockpit_unlock'),
            label: busy ? 'Waiting…' : LockScreenCockpitPolicy.unlockLabel,
            icon: Icons.fingerprint_rounded,
            onPressed: busy ? null : _unlock,
          ),
          const SizedBox(height: Space.s8),
          DsButton(
            key: const Key('locked_cockpit_call_112'),
            label: 'Call ${SafetyConstants.emergencyNumber}',
            icon: Icons.call_rounded,
            tone: DsButtonTone.sos,
            onPressed: () => launchUrl(Uri(scheme: 'tel', path: SafetyConstants.emergencyNumber)).ignore(),
          ),
          const SizedBox(height: Space.s8),
          DsButton(
            key: const Key('locked_cockpit_medical_id'),
            label: 'Medical ID',
            icon: Icons.medical_information_rounded,
            tone: DsButtonTone.outline,
            onPressed: () => AppSecurityNative.openMedicalId().ignore(),
          ),
        ],
      ),
    );
  }
}

/// Covers a private screen opened while locked: Unlock shows it, Back to ride closes it.
class LockedShield extends StatelessWidget {
  const LockedShield({super.key, required this.service});

  final LockScreenCockpitService service;

  @override
  Widget build(BuildContext context) {
    final busy = service.unlocking;
    return Material(
      key: const Key('locked_cockpit_shield'),
      color: AppTheme.bg,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Space.s24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.lock_outline_rounded, size: 48, color: AppTheme.primary),
                  const SizedBox(height: Space.s16),
                  Semantics(
                    header: true,
                    child: Text(LockScreenCockpitPolicy.shieldTitle, textAlign: TextAlign.center, style: AppText.title),
                  ),
                  const SizedBox(height: Space.s8),
                  Text(LockScreenCockpitPolicy.shieldBody,
                      textAlign: TextAlign.center, style: AppText.body.copyWith(color: AppTheme.textSecondary)),
                  const SizedBox(height: Space.s24),
                  DsButton(
                    key: const Key('locked_shield_unlock'),
                    label: busy ? 'Waiting…' : LockScreenCockpitPolicy.unlockLabel,
                    icon: Icons.fingerprint_rounded,
                    onPressed: busy ? null : () => service.unlockForPending().ignore(),
                  ),
                  const SizedBox(height: Space.s12),
                  DsButton(
                    key: const Key('locked_shield_back'),
                    label: LockScreenCockpitPolicy.backToRideLabel,
                    icon: Icons.two_wheeler_rounded,
                    tone: DsButtonTone.outline,
                    onPressed: service.guard.closePending,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
