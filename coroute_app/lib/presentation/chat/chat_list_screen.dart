import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/group_message_model.dart';
import '../../data/models/trip_history_model.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/chat_service.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/friends_service.dart';
import '../../data/services/ride_chat_store.dart';
import '../../data/services/trip_storage_service.dart';
import '../home/ride_start_view.dart';
import '../ride/messages_sheet.dart' show RideChatHistory;
import '../rider/rider_home_screen.dart';
import '../social/user_avatar.dart';
import '../widgets/feature_switch.dart';
import 'chat_thread_screen.dart';

/// Chat tab.
///  * v3.60 Messages: chats with friends and communities (text only, kept 90 days; gateway/src/chat.js),
///  * the live ride's chat (opens on the ride screen, where quick replies are safe while moving),
///  * the chats kept on this phone from the last rides (read only).
class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  static const String title = 'Chat';
  static const String emptyTitle = 'No chats yet';
  static const String emptyLine = 'Message your friends and communities, or chat with your group during a ride.';

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
    context.read<ChatService?>()?.refresh();
    final a = await RideChatStore.archivedRides();
    if (mounted) setState(() => _archive = a);
  }

  /// v3.60: pick a friend to message.
  Future<void> _newChat() async {
    final friends = context.read<FriendsService?>()?.friends ?? const <FriendEntry>[];
    if (friends.isEmpty) {
      showAppToast(context, 'Add friends in Community to message them.');
      return;
    }
    final picked = await showAppSheet<FriendEntry>(
      context,
      title: 'New message',
      isScrollControlled: true,
      builder: (ctx) => ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.6),
        child: ListView(shrinkWrap: true, children: [
          for (final f in friends)
            ListTile(
              key: Key('chat_pick_${f.username}'),
              minTileHeight: 56,
              leading: UserAvatar(label: f.displayName.isNotEmpty ? f.displayName : f.username, avatarUrl: f.avatarUrl, size: 40),
              title: Text(f.username, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: f.displayName.isEmpty ? null : Text(f.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => Navigator.pop(ctx, f),
            ),
        ]),
      ),
    );
    if (picked == null || !mounted) return;
    await ChatThreadScreen.openWithFriend(context, username: picked.username, avatarUrl: picked.avatarUrl);
    if (mounted) context.read<ChatService?>()?.refresh();
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
    final chatSvc = context.watch<ChatService?>();
    final chats = chatSvc?.chats ?? const <ChatSummary>[];
    final chatOn = context.featureOn(ChatService.friendFlag) || context.featureOn(ChatService.communityFlag);
    final loading = _archive == null;
    final empty = !loading && gid == null && archive.isEmpty && chats.isEmpty;

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
                Row(children: [
                  Expanded(child: Semantics(header: true, child: Text(ChatListScreen.title, style: AppText.headline.copyWith(fontSize: 28)))),
                  if (chatOn && context.featureOn(ChatService.friendFlag))
                    IconButton.filledTonal(
                      key: const Key('chat_new'),
                      tooltip: 'New message',
                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      onPressed: _newChat,
                      icon: const Icon(Icons.edit_square),
                    ),
                ]),
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
                // v3.60 Messages: friends and communities.
                if (chatOn && chats.isNotEmpty) ...[
                  const SectionTitle('Messages'),
                  const SizedBox(height: Space.s8),
                  DsCard(
                    key: const Key('chat_messages_list'),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    child: Column(children: [
                      for (var i = 0; i < chats.length; i++)
                        _ChatRow(
                          chat: chats[i],
                          divider: i < chats.length - 1,
                          onTap: () async {
                            await ChatThreadScreen.open(context, chatId: chats[i].chatId, title: chats[i].title, avatarUrl: chats[i].avatarUrl);
                            if (context.mounted) context.read<ChatService?>()?.refresh();
                          },
                        ),
                    ]),
                  ),
                  const SizedBox(height: 4),
                  Text('Text only. Messages are deleted after ${ChatService.keepDays} days.', style: AppText.caption),
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

/// v3.60 a friend or community chat in the list.
class _ChatRow extends StatelessWidget {
  final ChatSummary chat;
  final bool divider;
  final VoidCallback onTap;
  const _ChatRow({required this.chat, required this.divider, required this.onTap});

  static String _when(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    if (d.year == now.year && d.month == now.month && d.day == now.day) {
      final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
      return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'am' : 'pm'}';
    }
    const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${mo[d.month - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    final c = chat;
    final preview = c.lastPreview.isEmpty ? (c.isCommunity ? 'Community chat' : 'Say hello') : (c.lastMine ? 'You: ${c.lastPreview}' : c.lastPreview);
    return Semantics(
      button: true,
      label: '${c.title}. ${c.unread > 0 ? '${c.unread} unread. ' : ''}$preview',
      excludeSemantics: true,
      child: InkWell(
        key: Key('chat_row_${c.chatId}'),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 68),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(border: divider ? Border(bottom: BorderSide(color: AppTheme.border)) : null),
          child: Row(
            children: [
              c.isCommunity && c.avatarUrl == null
                  ? Container(width: 44, height: 44, decoration: BoxDecoration(color: AppTheme.tint, borderRadius: BorderRadius.circular(12)), child: Icon(Icons.groups_rounded, color: AppTheme.accentText))
                  : UserAvatar(label: c.title, avatarUrl: c.avatarUrl, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(fontSize: 15, fontWeight: c.unread > 0 ? FontWeight.w800 : null)),
                    Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: c.unread > 0 ? AppTheme.text : null)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(_when(c.lastAt), style: AppText.caption),
                  if (c.unread > 0) Badge(label: Text(c.unread > 99 ? '99+' : '${c.unread}')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
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
