import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ride_alert.dart';
import '../../core/ui/ui_tokens.dart';
import '../../data/services/group_safety_service.dart';
import '../safety/hold_sos_pill.dart';

/// 3.55 group safety cards in the cockpit alert slot (see GroupSafetyService). Taps are offered
/// only while the rider is slow ([GroupSafetyService.canTap]); at speed the cards are information
/// only, and nothing here is ever needed to keep riding safely.
class GroupSafetyCard extends StatelessWidget {
  final GroupSafetyNotice notice;
  final GroupSafetyService service;

  /// Raises the real SOS (the cockpit's one SOS path). When set, the missing-rider card shows the
  /// separate red "Send SOS" hold button.
  final VoidCallback? onSos;
  const GroupSafetyCard({super.key, required this.notice, required this.service, this.onSos});

  static AlertTier tierOf(GroupSafetyNotice n) => n.important ? AlertTier.important : AlertTier.normal;

  @override
  Widget build(BuildContext context) {
    final n = notice;
    final tap = service.canTap;
    String? action;
    VoidCallback? onAction;
    var more = <(String, VoidCallback)>[];
    switch (n.kind) {
      case GroupSafetyKind.missingRider:
        // Shown only while stopped: always tappable.
        final sos = onSos;
        return MissingRiderCard(
          title: n.title,
          message: n.message,
          onOk: service.answerOk,
          onNeedHelp: service.answerNeedHelp,
          onWaiting: service.answerWaiting,
          onSos: sos == null
              ? null
              : () {
                  service.answerSos();
                  sos();
                },
          onDismiss: () => service.dismiss(n),
        );
      case GroupSafetyKind.buddyAsked:
        action = "I'm OK";
        onAction = service.answerBuddyOk;
      case GroupSafetyKind.buddyCheck:
        if (tap) {
          final phone = n.phone;
          if (phone != null) {
            action = 'Call';
            onAction = () => launchUrl(Uri(scheme: 'tel', path: phone.replaceAll(' ', ''))).ignore();
          }
          more = [
            ('Send a check', () => service.checkBuddy()),
            ("They're fine", service.buddyFine),
            ('Ask group to wait', service.askGroupToWait),
          ];
        }
      case GroupSafetyKind.stretch:
        final s = n.suggestion;
        if (tap && s != null) {
          action = 'Set regroup point';
          onAction = () => service.setRegroupPoint(s);
        }
      case GroupSafetyKind.groupBreak:
        final s = n.suggestion;
        if (tap && s != null) {
          action = 'Plan stop';
          onAction = () => service.planBreakStop(s);
        }
      case GroupSafetyKind.buddyOk || GroupSafetyKind.riskyStretch:
        break;
    }
    final slowNote = !tap && (n.kind == GroupSafetyKind.buddyCheck || ((n.kind == GroupSafetyKind.stretch || n.kind == GroupSafetyKind.groupBreak) && n.suggestion != null));
    return RideAlert(
      tier: tierOf(n),
      title: n.title,
      message: [if (n.message.isNotEmpty) n.message, if (slowNote) 'Stop safely to act on it.'].join(' '),
      actionLabel: action,
      onAction: onAction,
      moreActions: more,
      onDismiss: () => service.dismiss(n),
    );
  }
}

/// The missing-rider check card ("Are you OK? The group is moving on"). Owner decision 3.55:
/// "I'm OK" and "Need help" (asks the group to wait / regroup) stay as before, and a clearly
/// separate red "Send SOS" button raises the real SOS. It must be held for 3 s, like the big
/// SOS button, so a glove or a bump cannot send it. Service-free (pure inputs) for tests.
class MissingRiderCard extends StatelessWidget {
  final String title;
  final String message;
  final VoidCallback onOk;
  final VoidCallback onNeedHelp;
  final void Function(String reason) onWaiting;
  final VoidCallback? onSos;
  final VoidCallback? onDismiss;

  const MissingRiderCard({
    super.key,
    required this.title,
    required this.message,
    required this.onOk,
    required this.onNeedHelp,
    required this.onWaiting,
    this.onSos,
    this.onDismiss,
  });

  static const String okLabel = "I'm OK";
  static const String needHelpLabel = 'Need help';

  /// Above the red button: what "Need help" does, and where the real SOS is.
  static const String needHelpNote = 'Need help asks the group to wait. For an emergency, hold Send SOS.';

  /// The quieter answers after "Need help": label and the STATUS reason sent.
  static const List<(String, String)> waitingChoices = [
    ('Waiting for fuel', 'FUELING'),
    ('Photo stop', 'PHOTO_STOP'),
    ('Taking a break', 'REST_BREAK'),
  ];

  @override
  Widget build(BuildContext context) {
    final sos = onSos;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RideAlert(
          tier: AlertTier.important,
          title: title,
          message: message,
          actionLabel: okLabel,
          onAction: onOk,
          moreActions: [
            (needHelpLabel, onNeedHelp),
            for (final (label, reason) in waitingChoices) (label, () => onWaiting(reason)),
          ],
          onDismiss: onDismiss,
        ),
        if (sos != null) ...[
          const SizedBox(height: 6),
          // Its own block under the card (on the map), so it is never mistaken for "Need help".
          Container(
            padding: const EdgeInsets.all(Space.s8),
            decoration: BoxDecoration(
              color: AppTheme.card,
              borderRadius: Radii.lgAll,
              border: Border.all(color: AppTheme.border, width: 2),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.s4, 0, Space.s4, Space.s8),
                child: Text(needHelpNote, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: AppTheme.text2)),
              ),
              HoldSosPill(key: const ValueKey('missingRiderSos'), onTriggered: sos),
            ]),
          ),
        ],
      ],
    );
  }
}

/// "Your buddy: Kiran" for the ride sheet (nothing when no buddy), with "Assign buddies" for the
/// lead of a large group.
class BuddyLine extends StatelessWidget {
  final GroupSafetyService service;
  final bool lead;
  final bool largeGroup;
  const BuddyLine({super.key, required this.service, this.lead = false, this.largeGroup = false});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final name = service.myBuddyName;
        if (name == null && !(lead && largeGroup)) return const SizedBox.shrink();
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.people_alt_rounded),
          title: Text(name == null ? 'Buddy pairs' : 'Your buddy: $name'),
          subtitle: name == null ? const Text('Each rider watches one buddy.') : null,
          trailing: lead && largeGroup
              ? TextButton(
                  onPressed: () {
                    final sent = service.assignBuddies();
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
                        content: Text(sent ? 'Buddies assigned.' : 'Could not assign buddies now. Try again with signal.')));
                  },
                  child: Text(name == null ? 'Assign buddies' : 'Reassign'),
                )
              : null,
        );
      },
    );
  }
}
