import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/services/friends_service.dart';
import 'people_screen.dart';

/// 3.55 Friends now live in the People hub (people_screen.dart): Friends · Crews · Requests with
/// search on top. Kept so existing entry points (pushes, notices) keep working: they open the hub on
/// Requests when friend requests are waiting, else on Friends.
class FriendsScreen extends StatelessWidget {
  const FriendsScreen({super.key});

  static PeopleSegment _segmentFor(BuildContext context) {
    final waiting = context.read<FriendsService?>()?.incoming.isNotEmpty ?? false;
    return waiting ? PeopleSegment.requests : PeopleSegment.friends;
  }

  static Future<void> open(BuildContext context) => PeopleScreen.open(context, segment: _segmentFor(context));

  @override
  Widget build(BuildContext context) => PeopleScreen(initial: _segmentFor(context));
}
