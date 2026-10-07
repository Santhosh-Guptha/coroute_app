import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/rider_model.dart';
import '../../data/services/convoy_service.dart';

/// A quick message: what the button says, what the group reads, and its card type.
class QuickMessage {
  final IconData icon;
  final String label;
  final String text;
  final String cardType;

  /// "Wait for me" is not a chat line: it asks the group to wait (a timed request).
  final bool isWait;

  const QuickMessage(this.icon, this.label, this.text, this.cardType, {this.isWait = false});
}

/// The one list of quick messages (the dashboard and the map had two different ones).
const List<QuickMessage> quickMessages = [
  QuickMessage(Icons.pan_tool_rounded, 'Wait for me', '', 'WAIT_2MIN', isWait: true),
  QuickMessage(Icons.local_gas_station_rounded, 'Need fuel', 'Looking for a fuel station soon.', 'FUEL'),
  QuickMessage(Icons.groups_rounded, 'Regroup here', 'Regroup here.', 'REGROUP'),
  QuickMessage(Icons.build_rounded, 'Bike problem', 'Small bike problem, slowing down.', 'MECHANICAL'),
  QuickMessage(Icons.warning_amber_rounded, 'Road hazard ahead', 'Road hazard ahead, take care.', 'HAZARD'),
  QuickMessage(Icons.thumb_up_alt_rounded, 'All good', 'All good, moving.', 'OK'),
];

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

  void _sendQuick(ConvoyService service, QuickMessage q) {
    if (q.isWait) {
      service.requestWait(widget.me.name);
    } else {
      service.sendGroupMessage(senderId: widget.me.userId, senderName: widget.me.name, text: q.text, isQuickCard: true, cardType: q.cardType);
    }
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
    final messages = service.allConvoys[widget.convoyId]?.messages ?? const [];
    final maxList = MediaQuery.sizeOf(context).height * 0.4;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: Space.s8,
          runSpacing: Space.s4,
          children: [
            for (final q in quickMessages)
              ActionChip(
                avatar: Icon(q.icon, size: 18, color: AppTheme.neonCyan),
                label: Text(q.label, style: AppText.label.copyWith(color: AppTheme.textPrimary)),
                materialTapTargetSize: MaterialTapTargetSize.padded,
                onPressed: () => _sendQuick(service, q),
              ),
          ],
        ),
        const SizedBox(height: Space.s8),
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
                      final msg = messages[messages.length - 1 - i];
                      final mine = msg.senderId == widget.me.userId;
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
                              if (!mine) Text(msg.senderName, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(fontWeight: FontWeight.w600)),
                              Text(msg.text, style: AppText.body),
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
