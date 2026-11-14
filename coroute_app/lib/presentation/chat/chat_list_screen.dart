import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/group_message_model.dart';
import '../../data/models/trip_history_model.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/ride_chat_store.dart';
import '../../data/services/trip_storage_service.dart';
import '../home/ride_start_view.dart';
import '../ride/messages_sheet.dart' show RideChatHistory;
import '../rider/rider_home_screen.dart';

/// v3.58 Chat tab. CoRoute's chat belongs to a ride (before, during and after; docs/features_355/ride_chat.md):
///  * the live ride's chat (opens on the ride screen, where quick replies are safe while moving),
///  * the chats kept on this phone from the last rides (read only),
///  * a clear empty state otherwise. There is no separate messaging backend (crew threads are a proposal).
class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  static const String title = 'Chat';
  static const String emptyTitle = 'No chats yet';
  static const String emptyLine = 'Chat opens with a ride: before, during and after. While riding, one-tap replies keep your hands on the bars.';

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  List<({String groupId, int count, GroupMessageModel? last})>? _archive;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final a = await RideChatStore.archivedRides();
    if (mounted) setState(() => _archive = a);
  }

  void _openHistory(String groupId, String title) {
    final me = context.read<AuthService?>()?.currentUserId ?? '';
    showAppSheet<void>(
      context,
      title: title,
      isScrollControlled: true,
      builder: (_) => SingleChildScrollView(child: RideChatHistory(groupId: groupId, myUserId: me)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final convoys = context.watch<ConvoyService?>();
    final gid = convoys?.activeGroupId;
    final live = gid == null ? const <GroupMessageModel>[] : convoys!.visibleMessages(gid);
    final unread = gid == null ? 0 : convoys!.unreadChat(gid);
    final trips = context.watch<TripStorageService?>()?.trips ?? const <TripHistoryModel>[];
    final archive = (_archive ?? const []).where((a) => a.groupId != gid).toList();
    final loading = _archive == null;
    final empty = !loading && gid == null && archive.isEmpty;

    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        bottom: false,
        child: ContentWidth(
          maxWidth: 680,
          child: AppRefresh(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
              physics: AppScrollBehavior.physics,
              children: [
                Semantics(header: true, child: Text(ChatListScreen.title, style: AppText.headline.copyWith(fontSize: 28))),
                const SizedBox(height: Space.s16),
                if (gid != null) ...[
                  const SectionTitle('Live ride'),
                  const SizedBox(height: Space.s8),
                  DsCard(
                    key: const Key('chat_live'),
                    accent: true,
                    onTap: () {
                      RiderHomeScreen.selectTab(context, HomeTab.ride);
                      showAppToast(context, 'Tap Chat on the ride screen.');
                    },
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.forum_outlined, color: AppTheme.accentText),
                            const SizedBox(width: 10),
                            Expanded(child: Text(convoys!.activeConvoy?.name.isNotEmpty == true ? convoys.activeConvoy!.name : 'Ride chat', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title)),
                            if (unread > 0) Badge(label: Text(unread > 9 ? '9+' : '$unread')),
                          ],
                        ),
                        const SizedBox(height: Space.s8),
                        if (live.isEmpty)
                          Text('No messages yet. Quick replies: fuel, break, wait for me, I\'m OK.', style: AppText.label)
                        else
                          for (final m in live.reversed.take(2).toList().reversed)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text('${m.senderName}: ${m.text}', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: AppTheme.text)),
                            ),
                        const SizedBox(height: Space.s8),
                        Text('Open on the ride screen', style: AppText.label.copyWith(color: AppTheme.accentText, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                  const SizedBox(height: Space.s24),
                ],
                if (loading)
                  const SkeletonRows(count: 3)
                else if (empty)
                  SizedBox(
                    height: 420,
                    child: EmptyState(
                      key: const Key('chat_empty'),
                      icon: Icons.forum_outlined,
                      title: ChatListScreen.emptyTitle,
                      message: ChatListScreen.emptyLine,
                      primaryLabel: 'Start a ride',
                      onPrimary: () => RideStartView.startRide(context),
                      secondaryLabel: 'Join with a code',
                      onSecondary: () => showJoinRideSheet(context),
                    ),
                  )
                else if (archive.isNotEmpty) ...[
                  const SectionTitle('Recent rides'),
                  const SizedBox(height: 2),
                  Text('Kept on this phone for your last 10 rides. Read only.', style: AppText.caption),
                  const SizedBox(height: Space.s8),
                  DsCard(
                    key: const Key('chat_archive'),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    child: Column(
                      children: [
                        for (var i = 0; i < archive.length; i++)
                          _ArchiveRow(
                            title: _titleOf(archive[i].groupId, trips),
                            last: archive[i].last,
                            count: archive[i].count,
                            divider: i < archive.length - 1,
                            onTap: () => _openHistory(archive[i].groupId, _titleOf(archive[i].groupId, trips)),
                          ),
                      ],
                    ),
                  ),
                ],
                if (!empty) ...[
                  const SizedBox(height: Space.s24),
                  DsCard(
                    tinted: true,
                    child: Row(
                      children: [
                        Icon(Icons.groups_outlined, color: AppTheme.accentText),
                        const SizedBox(width: 12),
                        Expanded(child: Text('Crews plan in polls. Start a ride with your crew to chat live.', style: AppText.label.copyWith(color: AppTheme.text))),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _titleOf(String groupId, List<TripHistoryModel> trips) {
    final t = trips.where((t) => t.groupId == groupId).firstOrNull;
    if (t == null) return 'Ride chat';
    final name = t.tripName.trim().isNotEmpty ? t.tripName.trim() : (t.destinationName.trim().isNotEmpty ? t.destinationName.trim() : 'Ride chat');
    final d = DateTime.fromMillisecondsSinceEpoch(t.startTimeEpochMs);
    const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return t.startTimeEpochMs > 0 ? '$name · ${d.day} ${mo[d.month - 1]}' : name;
  }
}

class _ArchiveRow extends StatelessWidget {
  final String title;
  final GroupMessageModel? last;
  final int count;
  final bool divider;
  final VoidCallback onTap;
  const _ArchiveRow({required this.title, required this.last, required this.count, required this.divider, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final l = last;
    final preview = l == null ? '$count messages' : '${l.senderName}: ${l.text}';
    return Semantics(
      button: true,
      label: '$title. $count messages. Last: $preview',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 68),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(border: divider ? Border(bottom: BorderSide(color: AppTheme.border)) : null),
          child: Row(
            children: [
              Container(width: 44, height: 44, decoration: BoxDecoration(color: AppTheme.tint, shape: BoxShape.circle), child: Icon(Icons.two_wheeler_rounded, color: AppTheme.accentText)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(fontSize: 15)),
                    Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label),
                  ],
                ),
              ),
              Text('$count', style: AppText.caption),
              Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
            ],
          ),
        ),
      ),
    );
  }
}
