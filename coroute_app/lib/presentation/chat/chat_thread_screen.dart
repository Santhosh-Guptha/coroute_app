import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/api_client.dart';
import '../../data/services/chat_service.dart';
import '../social/user_avatar.dart';

/// v3.60 one chat (a friend or a community): text only, newest at the bottom, kept 90 days.
/// Sending works like a messenger: the bubble shows at once, then is confirmed (or offers Retry).
class ChatThreadScreen extends StatefulWidget {
  final String chatId;
  final String title;
  final String? avatarUrl;
  const ChatThreadScreen({super.key, required this.chatId, required this.title, this.avatarUrl});

  static Future<void> open(BuildContext context, {required String chatId, required String title, String? avatarUrl}) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatThreadScreen(chatId: chatId, title: title, avatarUrl: avatarUrl)));

  /// Opens the chat with a friend (creates it on first use).
  static Future<void> openWithFriend(BuildContext context, {required String username, String? avatarUrl}) async {
    final svc = context.read<ChatService?>();
    if (svc == null) return;
    final (id, err) = await svc.openWith(username);
    if (!context.mounted) return;
    if (id == null) {
      showAppToast(context, err ?? 'Could not open the chat.', error: true);
      return;
    }
    await open(context, chatId: id, title: username, avatarUrl: avatarUrl);
  }

  @override
  State<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends State<ChatThreadScreen> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  List<ChatMessage> _messages = [];
  ChatMeta? _meta;
  bool _loading = true;
  bool _more = false;
  bool _loadingMore = false;
  String? _error;
  StreamSubscription<ChatMessage>? _in;
  StreamSubscription<(String, String)>? _del;
  ChatService? _svc;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _svc = context.read<ChatService?>();
      _svc?.setOpen(widget.chatId);
      _in = _svc?.incoming.listen((m) {
        if (m.chatId != widget.chatId || !mounted) return;
        if (_messages.any((x) => x.messageId == m.messageId)) return;
        setState(() => _messages = [..._messages, m]);
        _toBottom();
      });
      _del = _svc?.deleted.listen((d) {
        if (d.$1 == widget.chatId && mounted) setState(() => _messages = _messages.where((m) => m.messageId != d.$2).toList());
      });
      _load();
    });
    _scroll.addListener(() {
      if (_scroll.hasClients && _scroll.position.pixels >= _scroll.position.maxScrollExtent - 80) _older();
    });
  }

  @override
  void dispose() {
    _svc?.setOpen(null);
    _in?.cancel();
    _del?.cancel();
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final svc = _svc;
    if (svc == null) return;
    try {
      final (meta, list, more) = await svc.messages(widget.chatId);
      if (!mounted) return;
      setState(() {
        _meta = meta;
        _messages = list;
        _more = more;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Could not load the chat.';
        });
      }
    }
  }

  Future<void> _older() async {
    final svc = _svc;
    if (svc == null || !_more || _loadingMore || _messages.isEmpty) return;
    _loadingMore = true;
    try {
      final (_, list, more) = await svc.messages(widget.chatId, before: _messages.first.at);
      if (mounted) {
        setState(() {
          _messages = [...list, ..._messages];
          _more = more;
        });
      }
    } catch (_) {}
    _loadingMore = false;
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    });
  }

  Future<void> _send([ChatMessage? retry]) async {
    final svc = _svc;
    final text = retry?.text ?? _text.text.trim();
    if (svc == null || text.isEmpty) return;
    final clientId = retry?.clientId ?? svc.newClientId();
    final draft = ChatMessage(messageId: 'local_$clientId', chatId: widget.chatId, text: text, at: DateTime.now().millisecondsSinceEpoch, mine: true, clientId: clientId, pending: true);
    setState(() {
      _messages = [..._messages.where((m) => m.clientId != clientId), draft];
      if (retry == null) _text.clear();
    });
    _toBottom();
    try {
      final sent = await svc.send(widget.chatId, text, clientId: clientId);
      if (!mounted) return;
      setState(() => _messages = [for (final m in _messages) m.clientId == clientId ? sent : m]);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _messages = [for (final m in _messages) m.clientId == clientId ? m.copyWith(pending: false, failed: true) : m]);
      showAppToast(context, e.message, error: true);
    } catch (_) {
      if (mounted) setState(() => _messages = [for (final m in _messages) m.clientId == clientId ? m.copyWith(pending: false, failed: true) : m]);
    }
  }

  Future<void> _onLongPress(ChatMessage m) async {
    final canDelete = m.mine && !m.pending && !m.failed;
    final choice = await showAppSheet<String>(
      context,
      title: 'Message',
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
        DsListRow(icon: Icons.copy_rounded, label: 'Copy text', divider: canDelete, onTap: () => Navigator.pop(ctx, 'copy')),
        if (canDelete) DsListRow(icon: Icons.delete_outline_rounded, label: 'Delete for everyone', divider: false, onTap: () => Navigator.pop(ctx, 'delete')),
      ]),
    );
    if (!mounted || choice == null) return;
    if (choice == 'copy') {
      await Clipboard.setData(ClipboardData(text: m.text));
      if (mounted) showAppToast(context, 'Copied');
    } else if (choice == 'delete') {
      final err = await _svc?.deleteMessage(widget.chatId, m.messageId);
      if (!mounted) return;
      if (err != null) {
        showAppToast(context, err, error: true);
      } else {
        setState(() => _messages = _messages.where((x) => x.messageId != m.messageId).toList());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final meta = _meta;
    final community = meta?.kind == 'crew';
    final closed = meta?.closedLine;
    final reversed = _messages.reversed.toList();
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(children: [
          UserAvatar(label: widget.title, avatarUrl: widget.avatarUrl, size: 36),
          const SizedBox(width: 10),
          Expanded(child: Text(meta?.title.isNotEmpty == true ? meta!.title : widget.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
        ]),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _loading
                  ? const Padding(padding: EdgeInsets.all(20), child: SkeletonRows(count: 4))
                  : _error != null
                      ? ErrorState(title: _error!, onRetry: _load)
                      : _messages.isEmpty
                          ? EmptyState(
                              icon: Icons.chat_bubble_outline_rounded,
                              title: 'Say hello',
                              message: 'Text only. Messages are deleted after ${ChatService.keepDays} days.',
                            )
                          : ListView.builder(
                              key: const Key('chat_messages'),
                              controller: _scroll,
                              reverse: true,
                              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                              itemCount: reversed.length,
                              itemBuilder: (_, i) {
                                final m = reversed[i];
                                final older = i + 1 < reversed.length ? reversed[i + 1] : null;
                                final showName = community && !m.mine && (older == null || older.fromUsername != m.fromUsername);
                                return _Bubble(message: m, showName: showName, onLongPress: () => _onLongPress(m), onRetry: m.failed ? () => _send(m) : null);
                              },
                            ),
            ),
            if (closed != null)
              Container(
                key: const Key('chat_closed'),
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                color: AppTheme.tint,
                child: Text(closed, textAlign: TextAlign.center, style: AppText.label),
              )
            else
              _Composer(controller: _text, onSend: _send, enabled: meta != null),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  final bool enabled;
  const _Composer({required this.controller, required this.onSend, required this.enabled});

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final can = widget.enabled && widget.controller.text.trim().isNotEmpty;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(color: AppTheme.card, border: Border(top: BorderSide(color: AppTheme.border))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              key: const Key('chat_input'),
              controller: widget.controller,
              enabled: widget.enabled,
              minLines: 1,
              maxLines: 5,
              maxLength: ChatService.textMax,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(hintText: 'Message', counterText: '', border: InputBorder.none, isDense: true),
            ),
          ),
          IconButton(
            key: const Key('chat_send'),
            tooltip: 'Send',
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: can ? widget.onSend : null,
            icon: Icon(Icons.send_rounded, color: can ? AppTheme.accentText : AppTheme.muted),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatMessage message;
  final bool showName;
  final VoidCallback onLongPress;
  final VoidCallback? onRetry;
  const _Bubble({required this.message, required this.showName, required this.onLongPress, this.onRetry});

  static String _time(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    return '$h:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'am' : 'pm'}';
  }

  @override
  Widget build(BuildContext context) {
    final m = message;
    final mine = m.mine;
    final bg = mine ? AppTheme.brand : AppTheme.card;
    final fg = mine ? Colors.white : AppTheme.text;
    final status = m.failed ? 'Not sent' : m.pending ? 'Sending…' : _time(m.at);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
        child: GestureDetector(
          onLongPress: onLongPress,
          onTap: onRetry,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 3),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(mine ? 16 : 4),
                bottomRight: Radius.circular(mine ? 4 : 16),
              ),
              border: mine ? null : Border.all(color: AppTheme.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showName)
                  Text(m.fromUsername.isNotEmpty ? m.fromUsername : m.fromName, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: AppTheme.accentText, fontWeight: FontWeight.w700)),
                Text(m.text, style: AppText.body.copyWith(color: fg)),
                const SizedBox(height: 2),
                Align(
                  alignment: Alignment.bottomRight,
                  child: Text(onRetry != null ? 'Not sent. Tap to retry' : status, style: AppText.caption.copyWith(color: mine ? Colors.white70 : AppTheme.text2, fontSize: 11)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
