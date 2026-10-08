import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/group_message_model.dart';
import '../../data/models/outbox_item.dart';
import '../../data/models/rider_model.dart';
import '../../data/services/convoy_service.dart';
import 'incident_sheet.dart';

/// A quick reply: the words on the chip (also the chat text) and its card type.
class QuickMessage {
  final IconData icon;
  final String text;
  final String cardType;

  /// "Wait for me" is not a plain chat line: it asks the group to wait (a timed
  /// request that the gateway also posts in the chat).
  final bool isWait;

  const QuickMessage(this.icon, this.text, this.cardType, {this.isWait = false});
}

/// The one list of quick replies. Card types are at most 24 characters (gateway limit).
const List<QuickMessage> quickMessages = [
  QuickMessage(Icons.local_gas_station_rounded, 'Fuel stop', 'FUEL'),
  QuickMessage(Icons.pan_tool_rounded, 'Wait for me', 'WAIT_2MIN', isWait: true),
  QuickMessage(Icons.thumb_up_alt_rounded, 'All good', 'OK'),
  QuickMessage(Icons.speed_rounded, 'Slow down', 'SLOW_DOWN'),
  QuickMessage(Icons.coffee_rounded, 'Taking a break', 'BREAK'),
  QuickMessage(Icons.build_rounded, 'Bike problem', 'MECHANICAL'),
  QuickMessage(Icons.warning_amber_rounded, 'Road hazard ahead', 'HAZARD'),
];

/// Sends [QuickMessage]; returns true when it was handed to the connection.
typedef QuickReplySend = bool Function(QuickMessage message);

/// One wrap of large, glove friendly quick reply chips (52 dp high). One tap
/// sends, no confirm. The same chip is ignored for [cooldown] after it was
/// sent, so a double tap never sends twice. A short line under the chips says
/// "Sent: ..." (or that there is no connection) and clears itself.
class QuickReplyBar extends StatefulWidget {
  final QuickReplySend onSend;
  final List<QuickMessage> messages;

  /// True when a message that was accepted is only queued on the phone (no
  /// signal): the line then says "Waiting for signal: ..." instead of "Sent".
  final bool Function()? queued;

  const QuickReplyBar({super.key, required this.onSend, this.messages = quickMessages, this.queued});

  /// A second tap on the same chip within this time is ignored.
  static const Duration cooldown = Duration(seconds: 2);

  /// "Wait for me" alerts the whole group; the gateway allows 3 per 10 s, so it cools down longer.
  static const Duration waitCooldown = Duration(seconds: 4);

  /// How long the "Sent" line stays.
  static const Duration feedbackFor = Duration(seconds: 2);

  /// Chip height: above the 48 dp minimum for gloves.
  static const double chipHeight = 52;

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
    if (_cooling.containsKey(q.text)) return; // double tap: already sent
    final ok = widget.onSend(q);
    if (ok) {
      _cooling[q.text] = Timer(q.isWait ? QuickReplyBar.waitCooldown : QuickReplyBar.cooldown, () => _cooling.remove(q.text));
    }
    _feedbackClear?.cancel();
    _feedbackClear = Timer(QuickReplyBar.feedbackFor, () {
      if (mounted) setState(() => _feedback = null);
    });
    final waiting = ok && (widget.queued?.call() ?? false);
    setState(() {
      _feedbackOk = ok;
      _feedbackQueued = waiting;
      _feedback = !ok ? 'Not sent, no connection' : (waiting ? 'Waiting for signal: ${q.text}' : 'Sent: ${q.text}');
    });
  }

  @override
  Widget build(BuildContext context) {
    final feedback = _feedback;
    final color = (_feedbackOk && !_feedbackQueued) ? StatusColors.success : StatusColors.warning;
    final IconData icon = !_feedbackOk ? Icons.cloud_off_rounded : (_feedbackQueued ? Icons.schedule_rounded : Icons.check_circle_rounded);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: Space.s8,
          runSpacing: Space.s8,
          children: [
            for (final q in widget.messages) _QuickChip(message: q, onTap: () => _tap(q)),
          ],
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 28),
          child: Semantics(
            liveRegion: true,
            child: feedback == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(top: Space.s8),
                    child: Row(
                      children: [
                        Icon(icon, size: 16, color: color),
                        const SizedBox(width: Space.s4),
                        Flexible(
                          child: Text(feedback, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: color)),
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

class _QuickChip extends StatelessWidget {
  final QuickMessage message;
  final VoidCallback onTap;

  const _QuickChip({required this.message, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.elevatedCard,
      shape: RoundedRectangleBorder(borderRadius: Radii.mdAll, side: BorderSide(color: AppTheme.subtleBorder)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: QuickReplyBar.chipHeight, minWidth: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.s16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(message.icon, size: 22, color: AppTheme.neonCyan),
                const SizedBox(width: Space.s8),
                Flexible(
                  child: Text(
                    message.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.body.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the group messages sheet (quick messages, the conversation, a text field).
Future<void> showMessagesSheet(BuildContext context, {required String convoyId, required RiderModel me}) {
  return showAppSheet<void>(
    context,
    title: 'Messages',
    isScrollControlled: true,
    builder: (_) => MessagesView(convoyId: convoyId, me: me),
  );
}

class MessagesView extends StatefulWidget {
  final String convoyId;
  final RiderModel me;

  const MessagesView({super.key, required this.convoyId, required this.me});

  @override
  State<MessagesView> createState() => _MessagesViewState();
}

class _MessagesViewState extends State<MessagesView> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  /// The same paths as before: a wait request, or a chat line marked as a quick card.
  /// Without signal both wait in the phone's outbox and go out in order when the
  /// phone is back online, so the bar says "Waiting for signal".
  bool _sendQuick(ConvoyService service, QuickMessage q) {
    if (q.isWait) {
      service.requestWait(widget.me.name);
    } else {
      service.sendGroupMessage(senderId: widget.me.userId, senderName: widget.me.name, text: q.text, isQuickCard: true, cardType: q.cardType);
    }
    return true;
  }

  void _send(ConvoyService service) {
    final txt = _text.text.trim();
    if (txt.isEmpty) return;
    service.sendGroupMessage(senderId: widget.me.userId, senderName: widget.me.name, text: txt);
    _text.clear();
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<ConvoyService>();
    final sent = service.allConvoys[widget.convoyId]?.messages ?? const <GroupMessageModel>[];
    // My chat lines still in the outbox (no signal) follow the delivered ones, marked "Waiting for signal".
    final queued = [
      for (final o in service.outbox)
        if (o.type == 'CHAT' && o.groupId == widget.convoyId) o,
    ];
    final messages = <(GroupMessageModel?, OutboxItem?)>[
      for (final m in sent) (m, null),
      for (final o in queued) (null, o),
    ];
    final maxList = MediaQuery.sizeOf(context).height * 0.4;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        QuickReplyBar(onSend: (q) => _sendQuick(service, q), queued: () => !service.isOnline),
        const SizedBox(height: Space.s4),
        const Divider(height: 1),
        if (messages.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.s24),
            child: Text('No messages yet.', textAlign: TextAlign.center, style: AppText.body.copyWith(color: AppTheme.textSecondary)),
          )
        else
        Flexible(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxList),
            child: ListView.builder(
                    reverse: true,
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: Space.s8),
                    itemCount: messages.length,
                    itemBuilder: (context, i) {
                      final (msg, item) = messages[messages.length - 1 - i];
                      final mine = msg == null || msg.senderId == widget.me.userId;
                      final text = msg?.text ?? item?.payload['text']?.toString() ?? '';
                      return Align(
                        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: Space.s4),
                          padding: const EdgeInsets.symmetric(horizontal: Space.s12, vertical: Space.s8),
                          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.75),
                          decoration: BoxDecoration(
                            color: mine ? AppTheme.neonCyan.withOpacity(0.16) : AppTheme.elevatedCard,
                            borderRadius: Radii.mdAll,
                            border: Border.all(color: mine ? AppTheme.neonCyan.withOpacity(0.5) : AppTheme.subtleBorder),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (!mine)
                                Text(msg.senderName, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(fontWeight: FontWeight.w600)),
                              Text(text, style: AppText.body),
                              if (item != null) QueuedLine(failed: item.state == OutboxState.failed, sending: service.isOnline),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
        const Divider(height: 1),
        const SizedBox(height: Space.s8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _text,
                maxLength: 300,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(service),
                style: AppText.body,
                decoration: InputDecoration(
                  hintText: 'Message the group',
                  hintStyle: AppText.caption,
                  counterText: '',
                  filled: true,
                  fillColor: AppTheme.elevatedCard,
                  border: const OutlineInputBorder(borderRadius: Radii.mdAll, borderSide: BorderSide.none),
                ),
              ),
            ),
            const SizedBox(width: Space.s8),
            IconButton(
              tooltip: 'Send message',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: Icon(Icons.send_rounded, color: AppTheme.neonCyan),
              onPressed: () => _send(service),
            ),
          ],
        ),
      ],
    );
  }
}
