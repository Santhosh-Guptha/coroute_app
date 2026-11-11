import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/group_message_model.dart';
import '../../data/models/outbox_item.dart';
import '../../data/models/rider_model.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/ride_chat_store.dart';
import '../../domain/ride/ride_chat.dart';
import 'incident_sheet.dart';

// 3.55 ride chat (docs/features_355/ride_chat.md): one Chat button on the cockpit opens a compact
// sheet with the recent messages, big one-tap quick actions and, when stopped (or pillion), a text
// field. The rules (order, moving gate, spoken lines, unread) are in lib/domain/ride/ride_chat.dart.

/// The icon of each quick action (by [RideQuickAction.id]).
IconData quickActionIcon(String id) => switch (id) {
      'fuel' => Icons.local_gas_station_rounded,
      'break' => Icons.coffee_rounded,
      'wait' => Icons.pan_tool_rounded,
      'ok' => Icons.thumb_up_alt_rounded,
      'slow' => Icons.speed_rounded,
      'regroup' => Icons.groups_rounded,
      'onmyway' => Icons.two_wheeler_rounded,
      'arrived' => Icons.flag_rounded,
      _ => Icons.chat_bubble_rounded,
    };

/// The icon for a received quick card (older card types included).
IconData cardTypeIcon(String cardType) {
  final a = RideChat.byCardType(cardType);
  if (a != null) return quickActionIcon(a.id);
  return switch (cardType) {
    'MECHANICAL' => Icons.build_rounded,
    'HAZARD' => Icons.warning_amber_rounded,
    _ => Icons.chat_bubble_rounded,
  };
}

/// A quick reply chip: icon, 1-2 word label, the action behind it.
class QuickMessage {
  final IconData icon;
  final RideQuickAction action;

  const QuickMessage(this.icon, this.action);

  /// The chip words ("Fuel").
  String get label => action.label;

  /// The chat text sent ("Fuel stop").
  String get text => action.text;
  String get cardType => action.cardType;
  bool get isWait => action.isWait;
}

/// The quick replies in [order] (default order when null).
List<QuickMessage> quickMessagesFor(List<RideQuickAction>? order) => [
      for (final a in order ?? RideChat.actions) QuickMessage(quickActionIcon(a.id), a),
    ];

/// The quick replies in the default order.
final List<QuickMessage> quickMessages = quickMessagesFor(null);

/// Sends [QuickMessage]; returns true when it was handed to the connection.
typedef QuickReplySend = bool Function(QuickMessage message);

/// A grid of big, glove friendly quick action tiles (icon above 1-2 words, at least 64 dp high).
/// One tap sends, no confirm. The same tile is ignored for [cooldown] after it was sent, so a double
/// tap never sends twice. A short line under the tiles says "Sent: ..." and clears itself.
class QuickReplyBar extends StatefulWidget {
  final QuickReplySend onSend;
  final List<QuickMessage>? messages;

  /// True when a message that was accepted is only queued on the phone (no signal): the line then
  /// says "Waiting for signal: ..." instead of "Sent".
  final bool Function()? queued;

  const QuickReplyBar({super.key, required this.onSend, this.messages, this.queued});

  /// A second tap on the same tile within this time is ignored.
  static const Duration cooldown = Duration(seconds: 2);

  /// "Wait for me" alerts the whole group; the gateway allows 3 per 10 s, so it cools down longer.
  static const Duration waitCooldown = Duration(seconds: 4);

  /// How long the "Sent" line stays.
  static const Duration feedbackFor = Duration(seconds: 2);

  /// Tile height: well above the 48 dp minimum for gloves.
  static const double chipHeight = 64;

  @override
  State<QuickReplyBar> createState() => _QuickReplyBarState();
}

class _QuickReplyBarState extends State<QuickReplyBar> {
  final Map<String, Timer> _cooling = {};
  Timer? _feedbackClear;
  String? _feedback;
  bool _feedbackOk = true;
  bool _feedbackQueued = false;

  @override
  void dispose() {
    for (final t in _cooling.values) {
      t.cancel();
    }
    _feedbackClear?.cancel();
    super.dispose();
  }

  void _tap(QuickMessage q) {
    if (_cooling.containsKey(q.action.id)) return; // double tap: already sent
    HapticFeedback.lightImpact();
    final ok = widget.onSend(q);
    if (ok) {
      _cooling[q.action.id] = Timer(q.isWait ? QuickReplyBar.waitCooldown : QuickReplyBar.cooldown, () => _cooling.remove(q.action.id));
    }
    _feedbackClear?.cancel();
    _feedbackClear = Timer(QuickReplyBar.feedbackFor, () {
      if (mounted) setState(() => _feedback = null);
    });
    final waiting = ok && (widget.queued?.call() ?? false);
    setState(() {
      _feedbackOk = ok;
      _feedbackQueued = waiting;
      _feedback = !ok ? 'Not sent, no connection' : (waiting ? 'Waiting for signal: ${q.label}' : 'Sent: ${q.label}');
    });
  }

  @override
  Widget build(BuildContext context) {
    final feedback = _feedback;
    final messages = widget.messages ?? quickMessages;
    final color = (_feedbackOk && !_feedbackQueued) ? AppTheme.accentText : AppTheme.warnText;
    final IconData icon = !_feedbackOk ? Icons.cloud_off_rounded : (_feedbackQueued ? Icons.schedule_rounded : Icons.check_circle_rounded);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(builder: (context, box) {
          const gap = 8.0;
          // 4 tiles a row on most phones, 3 on narrow ones (320 dp with large text).
          final cols = box.maxWidth >= 340 ? 4 : 3;
          final tileW = ((box.maxWidth - gap * (cols - 1)) / cols).floorToDouble();
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final q in messages) SizedBox(width: tileW, child: _QuickTile(message: q, onTap: () => _tap(q))),
            ],
          );
        }),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 26),
          child: Semantics(
            liveRegion: true,
            child: feedback == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: [
                        Icon(icon, size: 16, color: color),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(feedback, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: color, fontWeight: FontWeight.w700)),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _QuickTile extends StatelessWidget {
  final QuickMessage message;
  final VoidCallback onTap;

  const _QuickTile({required this.message, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Send ${message.text}',
      excludeSemantics: true,
      child: Material(
        color: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md), side: BorderSide(color: AppTheme.border, width: 2)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: QuickReplyBar.chipHeight),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(message.icon, size: 26, color: AppTheme.accentText),
                  const SizedBox(height: 4),
                  Text(
                    message.label,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.label.copyWith(color: AppTheme.text, fontWeight: FontWeight.w700, height: 1.1),
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

/// The always-visible Chat button on the cockpit (56 dp, unread badge).
class RideChatButton extends StatelessWidget {
  final int unread;
  final VoidCallback onTap;

  const RideChatButton({super.key, required this.unread, required this.onTap});

  static const double size = 56;

  @override
  Widget build(BuildContext context) {
    final badge = ChatUnread.badge(unread);
    return Semantics(
      button: true,
      label: unread > 0 ? 'Chat, $unread unread' : 'Chat',
      excludeSemantics: true,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Material(
              color: AppTheme.card.withAlpha(235),
              shape: const CircleBorder(),
              elevation: 4,
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: const Key('cockpit_chat_button'),
                onTap: onTap,
                child: SizedBox(width: size, height: size, child: Icon(Icons.forum_rounded, color: AppTheme.accentText, size: 28)),
              ),
            ),
            if (badge.isNotEmpty)
              Positioned(
                right: -2,
                top: -2,
                child: IgnorePointer(
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: AppTheme.sos, borderRadius: BorderRadius.circular(11), border: Border.all(color: AppTheme.card, width: 2)),
                    child: Text(badge, style: AppText.caption.copyWith(color: Colors.white, fontWeight: FontWeight.w800, height: 1.0)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

bool _isMessagesSheetShowing = false;

/// Opens the ride chat sheet (recent messages, quick actions, a text field when stopped).
Future<void> showMessagesSheet(BuildContext context, {required String convoyId, required RiderModel me}) async {
  if (_isMessagesSheetShowing) return;
  _isMessagesSheetShowing = true;
  try {
    await showAppSheet<void>(
      context,
      title: 'Chat',
      isScrollControlled: true,
      builder: (_) => MessagesView(convoyId: convoyId, me: me),
    );
  } finally {
    _isMessagesSheetShowing = false;
  }
}

/// "14:05" for a message time.
String chatTime(int epochMs) {
  if (epochMs <= 0) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(epochMs);
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

class MessagesView extends StatefulWidget {
  final String convoyId;
  final RiderModel me;

  /// Tests: force the moving gate (null: ConvoyService.chatCanType).
  final bool? canTypeOverride;

  const MessagesView({super.key, required this.convoyId, required this.me, this.canTypeOverride});

  @override
  State<MessagesView> createState() => _MessagesViewState();
}

class _MessagesViewState extends State<MessagesView> {
  final _text = TextEditingController();
  ConvoyService? _service;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = context.read<ConvoyService>();
    if (!identical(s, _service)) {
      _service = s;
      // Everything in the open sheet counts as read (badge back to 0, no banner).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _service?.setChatOpen(widget.convoyId);
      });
    }
  }

  @override
  void dispose() {
    final s = _service;
    if (s != null) {
      // After the teardown: a listener notification while the tree is locked is not allowed.
      Future.microtask(() => s.setChatOpen(null));
    }
    _text.dispose();
    super.dispose();
  }

  void _send(ConvoyService service) {
    final txt = _text.text.trim();
    if (txt.isEmpty) return;
    _text.clear();
    service.sendGroupMessage(groupId: widget.convoyId, senderId: widget.me.userId, senderName: widget.me.name, text: txt);
  }

  Future<void> _messageActions(ConvoyService service, GroupMessageModel m) async {
    final name = RideChat.firstName(m.senderName);
    final choice = await showAppSheet<String>(
      context,
      title: name,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DsButton(label: 'Hide messages from $name', icon: Icons.visibility_off_rounded, tone: DsButtonTone.outline, onPressed: () => Navigator.pop(ctx, 'hide')),
          const SizedBox(height: Space.s12),
          DsButton(label: 'Report message', icon: Icons.flag_rounded, tone: DsButtonTone.outline, onPressed: () => Navigator.pop(ctx, 'report')),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (choice == 'hide') {
      service.setChatHidden(m.authorId, true);
      messenger?.showSnackBar(SnackBar(content: Text('Messages from $name are hidden')));
    } else if (choice == 'report') {
      final ok = service.reportChatMessage(m, hide: true);
      messenger?.showSnackBar(SnackBar(content: Text(ok ? 'Reported. Messages from $name are hidden' : 'Not sent, no connection')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<ConvoyService>();
    final sent = service.visibleMessages(widget.convoyId);
    // My chat lines still in the outbox (no signal) follow the delivered ones, marked "Waiting for signal".
    final queued = [
      for (final o in service.outbox)
        if (o.type == 'CHAT' && o.groupId == widget.convoyId) o,
    ];
    final messages = <(GroupMessageModel?, OutboxItem?)>[
      for (final m in sent) (m, null),
      for (final o in queued) (null, o),
    ];
    final canType = widget.canTypeOverride ?? service.chatCanType;
    final screenH = MediaQuery.sizeOf(context).height;
    final sheetH = (screenH * 0.68).clamp(360.0, 720.0);

    return SizedBox(
      height: sheetH,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.forum_outlined, size: 36, color: AppTheme.muted),
                        const SizedBox(height: 8),
                        Text('No messages yet.', textAlign: TextAlign.center, style: AppText.body.copyWith(color: AppTheme.text2)),
                      ],
                    ),
                  )
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: messages.length,
                    itemBuilder: (context, i) {
                      final (msg, item) = messages[messages.length - 1 - i];
                      final mine = msg == null || msg.authorId == widget.me.userId;
                      return ChatLineTile(
                        name: mine ? 'You' : (msg.senderName.isEmpty ? 'Rider' : msg.senderName),
                        text: msg?.text ?? item?.payload['text']?.toString() ?? '',
                        time: chatTime(msg?.timestamp ?? item?.createdAt ?? 0),
                        quickIcon: (msg?.isQuickCard ?? item?.payload['isQuickCard'] == true) ? cardTypeIcon(msg?.cardType ?? item?.payload['cardType']?.toString() ?? '') : null,
                        mine: mine,
                        footer: item != null ? QueuedLine(failed: item.state == OutboxState.failed, sending: service.isOnline) : null,
                        onLongPress: (msg != null && !mine && msg.authorId != 'SYSTEM') ? () => _messageActions(service, msg) : null,
                      );
                    },
                  ),
          ),
          Divider(height: 2, thickness: 2, color: AppTheme.border),
          const SizedBox(height: 10),
          QuickReplyBar(
            messages: quickMessagesFor(service.quickActions),
            onSend: (q) => service.sendQuickAction(q.action, groupId: widget.convoyId),
            queued: () => !service.isOnline,
          ),
          if (canType)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _text,
                      maxLength: RideChat.maxTextChars,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(service),
                      style: AppText.body,
                      decoration: InputDecoration(
                        hintText: 'Message the group',
                        hintStyle: AppText.label,
                        counterText: '',
                        filled: true,
                        fillColor: AppTheme.soft,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.md), borderSide: BorderSide(color: AppTheme.border, width: 2)),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.md), borderSide: BorderSide(color: AppTheme.border, width: 2)),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.md), borderSide: BorderSide(color: AppTheme.accentText, width: 2)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Material(
                    color: AppTheme.brand,
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: IconButton(
                      tooltip: 'Send message',
                      constraints: const BoxConstraints(minWidth: 52, minHeight: 52),
                      icon: const Icon(Icons.send_rounded, color: Colors.white, size: 22),
                      onPressed: () => _send(service),
                    ),
                  ),
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Icon(Icons.two_wheeler_rounded, size: 18, color: AppTheme.muted),
                  const SizedBox(width: 6),
                  Expanded(child: Text(RideChatTexts.movingHint, style: AppText.label.copyWith(color: AppTheme.text2))),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class RideChatTexts {
  RideChatTexts._();

  /// Under the quick actions while moving (typing hidden).
  static const String movingHint = 'Riding: one-tap replies only. Stop to type.';

  /// Trip summary section title.
  static const String historyTitle = 'Ride chat';
}

/// One chat line: rider name and time, then the text (a quick card shows its icon).
class ChatLineTile extends StatelessWidget {
  final String name;
  final String text;
  final String time;
  final IconData? quickIcon;
  final bool mine;
  final Widget? footer;
  final VoidCallback? onLongPress;

  const ChatLineTile({super.key, required this.name, required this.text, required this.time, this.quickIcon, this.mine = false, this.footer, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    final icon = quickIcon;
    return InkWell(
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(Radii.md),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: mine ? AppTheme.tint : AppTheme.soft,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: mine ? AppTheme.accentText : AppTheme.border, width: mine ? 2 : 1),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (icon != null) ...[
              Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 22, color: AppTheme.accentText)),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: AppTheme.accentText, fontWeight: FontWeight.w700)),
                      ),
                      if (time.isNotEmpty) Text(time, style: AppText.caption.copyWith(color: AppTheme.muted)),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(text, style: AppText.body.copyWith(fontWeight: icon != null ? FontWeight.w600 : null)),
                  ?footer,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The chat of an ended ride (read only) for the trip summary. Nothing when none was kept.
class RideChatHistory extends StatefulWidget {
  final String groupId;
  final String myUserId;

  /// Tests: messages instead of the phone's archive.
  final List<GroupMessageModel>? messages;

  const RideChatHistory({super.key, required this.groupId, required this.myUserId, this.messages});

  @override
  State<RideChatHistory> createState() => _RideChatHistoryState();
}

class _RideChatHistoryState extends State<RideChatHistory> {
  List<GroupMessageModel> _messages = const [];
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    final given = widget.messages;
    if (given != null) {
      _messages = given;
    } else {
      RideChatStore.loadArchived(widget.groupId).then((m) {
        if (mounted) setState(() => _messages = m);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hidden = context.select<ConvoyService?, Set<String>>((s) => s?.chatHidden ?? const <String>{});
    final all = ChatRules.visible(_messages, (m) => m.authorId, hidden);
    if (all.isEmpty) return const SizedBox.shrink();
    const collapsed = 5;
    final shown = _expanded || all.length <= collapsed ? all : all.sublist(all.length - collapsed);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 20),
        Semantics(header: true, child: DsSectionHeader(RideChatTexts.historyTitle)),
        const SizedBox(height: 8),
        for (final m in shown)
          ChatLineTile(
            name: m.authorId == widget.myUserId ? 'You' : (m.senderName.isEmpty ? 'Rider' : m.senderName),
            text: m.text,
            time: chatTime(m.timestamp),
            quickIcon: m.isQuickCard ? cardTypeIcon(m.cardType) : null,
            mine: m.authorId == widget.myUserId,
          ),
        if (!_expanded && all.length > collapsed)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => setState(() => _expanded = true),
              child: Text('Show all ${all.length}'),
            ),
          ),
      ],
    );
  }
}

/// Settings > More > "Chat quick replies": the order of the quick action tiles (Move up / Move down,
/// big buttons; saved on the phone).
Future<void> showQuickActionOrderSheet(BuildContext context) async {
  final service = context.read<ConvoyService?>();
  final saved = service != null ? [for (final a in service.quickActions) a.id] : [for (final a in RideChat.ordered(await RideChatStore.loadOrder())) a.id];
  if (!context.mounted) return;
  await showAppSheet<void>(
    context,
    title: QuickActionOrderView.title,
    isScrollControlled: true,
    builder: (_) => QuickActionOrderView(
      initial: saved,
      onChanged: (ids) {
        if (service != null) {
          service.setQuickActionOrder(ids);
        } else {
          RideChatStore.saveOrder(ids).ignore();
        }
      },
    ),
  );
}

class QuickActionOrderView extends StatefulWidget {
  final List<String> initial;
  final ValueChanged<List<String>> onChanged;

  const QuickActionOrderView({super.key, required this.initial, required this.onChanged});

  static const String title = 'Chat quick replies';

  @override
  State<QuickActionOrderView> createState() => _QuickActionOrderViewState();
}

class _QuickActionOrderViewState extends State<QuickActionOrderView> {
  late List<String> _ids = [for (final a in RideChat.ordered(widget.initial)) a.id];

  void _move(String id, bool up) {
    final next = RideChat.move(_ids, id, up: up);
    setState(() => _ids = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < _ids.length; i++)
          if (RideChat.byId(_ids[i]) case final a?)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(quickActionIcon(a.id), color: AppTheme.accentText),
                  const SizedBox(width: 12),
                  Expanded(child: Text(a.label, style: AppText.body.copyWith(fontWeight: FontWeight.w600))),
                  IconButton(
                    tooltip: 'Move ${a.label} up',
                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                    onPressed: i == 0 ? null : () => _move(a.id, true),
                    icon: const Icon(Icons.arrow_upward_rounded),
                  ),
                  IconButton(
                    tooltip: 'Move ${a.label} down',
                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                    onPressed: i == _ids.length - 1 ? null : () => _move(a.id, false),
                    icon: const Icon(Icons.arrow_downward_rounded),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}
