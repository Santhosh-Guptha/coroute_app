import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/rider_model.dart';
import '../../data/services/convoy_service.dart';
import '../../domain/garage/bike_type.dart';
import '../../domain/ride/pillion_seat.dart';
import '../garage/bike_silhouette.dart';

/// 3.55 pillion seat: the pillion picks the bike they sit on from the group's riders (a bike of
/// their own and no pillion yet), sees "You'll ride pillion on Asha's Royal Enfield Classic 350
/// (Red). Confirm?" and confirms. The gateway links the seat and tells everyone; the rider may
/// decline within a minute. Never blocks anything: closing the sheet keeps the ride as it is.
Future<void> showPillionSeatSheet(BuildContext context, ConvoyService service) async {
  final convoy = service.activeConvoy;
  final myId = service.myUserId;
  if (convoy == null || myId == null) return;
  final me = convoy.riders[myId];
  final seated = me != null && me.isCoRiding && convoy.riders.containsKey(me.ridingWithUserId);
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTheme.card,
    constraints: const BoxConstraints(maxWidth: 600),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (sheet) {
      final list = PillionSeat.candidates(convoy.riders, myId);
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text('Whose bike are you on?', style: TextStyle(color: AppTheme.text, fontSize: 18, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(height: 4),
              Text('Your group sees one bike with two people. Your phone keeps its safety features on.',
                  style: TextStyle(color: AppTheme.text2, fontSize: 13)),
              const SizedBox(height: 12),
              if (list.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text('No free bike in this ride right now. Ask your rider to join the ride first.',
                      style: TextStyle(color: AppTheme.text2)),
                ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final r in list)
                      ListTile(
                        key: ValueKey('pillionSeat_${r.userId}'),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                        leading: BikeSilhouette(
                          type: BikeType.parse(r.vehicleKind) ?? BikeType.commuter,
                          colour: bikeColourOf(r.vehicleColor),
                          width: 56,
                        ),
                        title: Text(r.name, style: TextStyle(color: AppTheme.text, fontWeight: FontWeight.w700)),
                        subtitle: Text(PillionSeat.bikeLine(r), style: TextStyle(color: AppTheme.text2)),
                        onTap: () async {
                          Navigator.of(sheet).pop();
                          await confirmPillionSeat(context, service, r);
                        },
                      ),
                  ],
                ),
              ),
              if (seated)
                TextButton(
                  onPressed: () {
                    service.unseatPillion();
                    Navigator.of(sheet).pop();
                  },
                  child: const Text('I am not riding pillion'),
                ),
              TextButton(
                onPressed: () {
                  service.dismissPillionPick();
                  Navigator.of(sheet).pop();
                },
                child: const Text('Not now'),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// "You'll ride pillion on Asha's Royal Enfield Classic 350 (Red). Confirm?" then the seat.
Future<bool> confirmPillionSeat(BuildContext context, ConvoyService service, RiderModel rider) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('Ride pillion?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          BikeSilhouette(
            type: BikeType.parse(rider.vehicleKind) ?? BikeType.commuter,
            colour: bikeColourOf(rider.vehicleColor),
            width: 120,
            people: 2,
          ),
          const SizedBox(height: 12),
          Text(PillionSeat.confirmText(rider)),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(d).pop(false), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('pillionSeatConfirm'), onPressed: () => Navigator.of(d).pop(true), child: const Text('Confirm')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return false;
  final sent = service.seatPillion(rider.userId);
  if (!sent) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Could not pick this bike now. Try again.')));
  }
  return sent;
}
