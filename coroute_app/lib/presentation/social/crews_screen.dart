import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/services/crews_service.dart';
import 'people_screen.dart';

/// 3.55 Crews now live in the People hub (people_screen.dart, segment Crews; crew invitations are
/// under Requests). Kept so existing entry points (crew pushes) keep working.
class CrewsScreen extends StatelessWidget {
  const CrewsScreen({super.key});

  static PeopleSegment _segmentFor(BuildContext context) {
    final invites = context.read<CrewsService?>()?.invites.isNotEmpty ?? false;
    return invites ? PeopleSegment.requests : PeopleSegment.crews;
  }

  static Future<void> open(BuildContext context) => PeopleScreen.open(context, segment: _segmentFor(context));

  @override
  Widget build(BuildContext context) => PeopleScreen(initial: _segmentFor(context));
}
