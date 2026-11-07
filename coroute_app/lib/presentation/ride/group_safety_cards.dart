import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/ui/ride_alert.dart';
import '../../data/services/group_safety_service.dart';

/// 3.55 group safety cards in the cockpit alert slot (see GroupSafetyService). Taps are offered
/// only while the rider is slow ([GroupSafetyService.canTap]); at speed the cards are information
/// only, and nothing here is ever needed to keep riding safely.
class GroupSafetyCard extends StatelessWidget {
  final GroupSafetyNotice notice;
  final GroupSafetyService service;
  const GroupSafetyCard({super.key, required this.notice, required this.service});

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
        action = "I'm OK";
        onAction = service.answerOk;
        more = [
          ('Need help', service.answerNeedHelp),
          ('Waiting for fuel', () => service.answerWaiting('FUELING')),
          ('Photo stop', () => service.answerWaiting('PHOTO_STOP')),
          ('Taking a break', () => service.answerWaiting('REST_BREAK')),
        ];
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
