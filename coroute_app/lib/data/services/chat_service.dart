import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';

import '../../domain/notify/notice_dedupe.dart';
import 'api_client.dart';
import 'feature_flags_service.dart';
import 'realtime_service.dart';

String? _avatar(Object? v) {
  final s = v?.toString() ?? '';
  return s.startsWith('/api/avatars/') ? s : null;
}

int _i(Object? v) => v is num ? v.toInt() : 0;

/// One chat in the list (GET /chats): a friend or a community.
@immutable
class ChatSummary {
  final String chatId;
  final String kind; // 'dm' | 'crew'
  final String title;
  final String subtitle;
  final String? avatarUrl;
  final int lastAt;
  final String lastPreview;
  final bool lastMine;
  final int unread;
  final String? crewId;
  const ChatSummary({
    required this.chatId,
    required this.kind,
    required this.title,
    this.subtitle = '',
    this.avatarUrl,
    this.lastAt = 0,
    this.lastPreview = '',
    this.lastMine = false,
    this.unread = 0,
    this.crewId,
  });
  bool get isCommunity => kind == 'crew';
  factory ChatSummary.fromJson(Map m) => ChatSummary(
        chatId: m['chatId']?.toString() ?? '',
        kind: m['kind']?.toString() ?? 'dm',
        title: m['title']?.toString() ?? '',
        subtitle: m['subtitle']?.toString() ?? '',
        avatarUrl: _avatar(m['avatarUrl']),
        lastAt: _i(m['lastAt']),
        lastPreview: m['lastPreview']?.toString() ?? '',
        lastMine: m['lastMine'] == true,
        unread: _i(m['unread']),
        crewId: m['crewId']?.toString(),
      );
}

/// One text message. [pending] = sent from this phone and not confirmed yet.
@immutable
class ChatMessage {
  final String messageId;
  final String chatId;
  final String text;
  final int at;
  final bool mine;
  final String fromUsername;
  final String fromName;
  final String? fromAvatar;
  final String? clientId;
  final bool pending;
  final bool failed;
  const ChatMessage({
    required this.messageId,
    required this.chatId,
    required this.text,
    required this.at,
    required this.mine,
    this.fromUsername = '',
    this.fromName = '',
    this.fromAvatar,
    this.clientId,
    this.pending = false,
    this.failed = false,
  });
  factory ChatMessage.fromJson(Map m) {
    final from = m['from'] is Map ? m['from'] as Map : const {};
    return ChatMessage(
      messageId: m['messageId']?.toString() ?? '',
      chatId: m['chatId']?.toString() ?? '',
      text: m['text']?.toString() ?? '',
      at: _i(m['at']),
      mine: m['mine'] == true,
      fromUsername: from['username']?.toString() ?? '',
      fromName: from['displayName']?.toString() ?? '',
      fromAvatar: _avatar(from['avatarUrl']),
      clientId: m['clientId']?.toString(),
    );
  }
  ChatMessage copyWith({String? messageId, int? at, bool? pending, bool? failed}) => ChatMessage(
        messageId: messageId ?? this.messageId,
        chatId: chatId,
        text: text,
        at: at ?? this.at,
        mine: mine,
        fromUsername: fromUsername,
        fromName: fromName,
        fromAvatar: fromAvatar,
        clientId: clientId,
        pending: pending ?? this.pending,
        failed: failed ?? this.failed,
      );
}

/// The header facts of an open chat (GET /chats/:id/messages `chat`).
@immutable
class ChatMeta {
  final String chatId;
  final String kind;
  final String title;
  final bool canSend;
  final String? closedReason;
  final int? chatMembersMax;
  final String? crewId;
  final String? username;
  const ChatMeta({required this.chatId, required this.kind, required this.title, this.canSend = true, this.closedReason, this.chatMembersMax, this.crewId, this.username});
  factory ChatMeta.fromJson(Map m) => ChatMeta(
        chatId: m['chatId']?.toString() ?? '',
        kind: m['kind']?.toString() ?? 'dm',
        title: m['title']?.toString() ?? '',
        canSend: m['canSend'] != false,
        closedReason: m['closedReason']?.toString(),
        chatMembersMax: m['chatMembersMax'] is num ? (m['chatMembersMax'] as num).toInt() : null,
        crewId: m['crewId']?.toString(),
        username: m['username']?.toString(),
      );

  /// Why I cannot write here, in plain words (null when I can).
  String? get closedLine => canSend
      ? null
      : switch (closedReason) {
          'NOT_FRIENDS' => 'You can chat with friends only.',
          'BLOCKED' => 'You cannot message this rider.',
          'TOO_BIG' => 'Community chat is for communities of up to ${chatMembersMax ?? 50} members.',
          'PLAN' => 'Chat is not included in this plan.',
          _ => 'Chat is turned off for now.',
        };
}

/// v3.60 chat with friends and communities (gateway/src/chat.js): text only, kept 90 days.
///
/// The Messages badge counts unread chat messages only; ride alerts never count here (they have their own
/// Alerts badge). While I am on a ride the gateway sends no chat push and this service shows no notice; the
/// messages are waiting when the ride ends.
class ChatService extends ChangeNotifier {
  ChatService(this._api, {RealtimeService? realtime, bool autoStart = true, this.isRiding}) : _rt = realtime {
    if (autoStart) start();
  }

  static const String friendFlag = 'friendChat';
  static const String communityFlag = 'communityChat';
  static const int keepDays = 90;
  static const int textMax = 1000;

  final ApiClient _api;
  final RealtimeService? _rt;

  /// True while this rider is on a ride (no chat notices then). Set by the app shell.
  bool Function()? isRiding;
  StreamSubscription<Map<String, dynamic>>? _sub;
  AppLifecycleListener? _lifecycle;
  final StreamController<ChatMessage> _incoming = StreamController<ChatMessage>.broadcast();
  final StreamController<(String, String)> _deleted = StreamController<(String, String)>.broadcast();
  bool _started = false;
  bool _disposed = false;
  bool _hadToken = false;
  final _rand = Random();

  List<ChatSummary> _chats = const [];
  int _unread = 0;
  bool _loaded = false;
  String? _openChatId;
  String? _lastNotice;

  List<ChatSummary> get chats => _chats;

  /// The chat open on screen (null: none). A push for it shows nothing.
  String? get openChatId => _openChatId;

  /// True while riding: chat notices stay quiet.
  bool get quiet => isRiding?.call() ?? false;
  bool get loaded => _loaded;

  /// Unread chat messages (friends + communities). Not ride alerts.
  int get unread => (FeatureFlagsService.on(friendFlag) || FeatureFlagsService.on(communityFlag)) ? _unread : 0;

  /// New messages for the open chat screen.
  Stream<ChatMessage> get incoming => _incoming.stream;
  Stream<(String chatId, String messageId)> get deleted => _deleted.stream;

  /// "Anu: see you at 6" for a toast when a message arrives on another screen (cleared on read).
  String? takeNotice() {
    final n = _lastNotice;
    _lastNotice = null;
    return n;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void start() {
    if (_started) return;
    _started = true;
    _hadToken = _api.hasToken;
    _sub = _rt?.events.listen(_onEvent);
    _api.addListener(_onApiChanged);
    try {
      _lifecycle = AppLifecycleListener(onResume: () => refresh());
    } catch (_) {}
    if (_api.hasToken) refresh();
  }

  void _onApiChanged() {
    final has = _api.hasToken;
    if (has && !_hadToken) refresh();
    if (!has && _hadToken) {
      _chats = const [];
      _unread = 0;
      _loaded = false;
      _notify();
    }
    _hadToken = has;
  }

  void _onEvent(Map<String, dynamic> e) {
    final type = e['type']?.toString();
    if (type == 'CHAT_DELETED') {
      final c = e['chatId']?.toString() ?? '';
      final m = e['messageId']?.toString() ?? '';
      if (!_deleted.isClosed) _deleted.add((c, m));
      return;
    }
    if (type != 'CHAT_MESSAGE' || e['message'] is! Map) return;
    final msg = ChatMessage.fromJson(e['message'] as Map);
    final fresh = NoticeDedupe.shared.firstTime(e['eventId']);
    if (!_incoming.isClosed) _incoming.add(msg);
    if (msg.chatId == _openChatId) {
      markRead(msg.chatId);
      return;
    }
    // Riding: count it, never announce it.
    if (fresh && !(isRiding?.call() ?? false)) {
      final who = e['username']?.toString() ?? 'A rider';
      final crew = e['crewName']?.toString();
      _lastNotice = crew == null ? '$who: ${e['preview'] ?? ''}' : '$who in $crew: ${e['preview'] ?? ''}';
    }
    _unread++;
    _notify();
    refresh();
  }

  /// The chat screen of [chatId] is open (null: closed): its messages count as read.
  void setOpen(String? chatId) {
    _openChatId = chatId;
    if (chatId != null) markRead(chatId);
  }

  Future<void> refresh() async {
    if (_disposed || !_api.hasToken) return;
    if (!FeatureFlagsService.on(friendFlag) && !FeatureFlagsService.on(communityFlag)) return;
    try {
      final res = await _api.get('/chats');
      if (res is! Map) return;
      _chats = res['chats'] is List ? (res['chats'] as List).whereType<Map>().map(ChatSummary.fromJson).toList() : const [];
      _unread = _i(res['unread']);
      _loaded = true;
      _notify();
    } catch (e) {
      debugPrint('Chats not refreshed: $e');
    }
  }

  /// Opens (or finds) the chat with a friend. Returns (chatId, error).
  Future<(String?, String?)> openWith(String username) async {
    try {
      final res = await _api.post('/chats/dm', {'username': username});
      final c = res is Map && res['chat'] is Map ? res['chat'] as Map : const {};
      return (c['chatId']?.toString(), null);
    } on ApiException catch (e) {
      return (null, e.message);
    } catch (_) {
      return (null, 'Could not reach CoRoute. Try again.');
    }
  }

  /// A page of messages, oldest first. [before] = load older than this time.
  Future<(ChatMeta, List<ChatMessage>, bool)> messages(String chatId, {int before = 0}) async {
    final res = await _api.get('/chats/${Uri.encodeComponent(chatId)}/messages${before > 0 ? '?before=$before' : ''}');
    final m = res is Map ? res : const {};
    final meta = ChatMeta.fromJson(m['chat'] is Map ? m['chat'] as Map : {'chatId': chatId});
    final list = m['messages'] is List ? (m['messages'] as List).whereType<Map>().map(ChatMessage.fromJson).toList() : <ChatMessage>[];
    return (meta, list, m['more'] == true);
  }

  String newClientId() => 'c${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${_rand.nextInt(1 << 30).toRadixString(36)}';

  /// Sends a text. Returns the confirmed message, or throws ApiException.
  Future<ChatMessage> send(String chatId, String text, {required String clientId}) async {
    final res = await _api.post('/chats/${Uri.encodeComponent(chatId)}/messages', {'text': text, 'clientId': clientId});
    final m = res is Map && res['message'] is Map ? res['message'] as Map : const {};
    refresh();
    return ChatMessage.fromJson(m);
  }

  Future<void> markRead(String chatId) async {
    final i = _chats.indexWhere((c) => c.chatId == chatId);
    if (i >= 0 && _chats[i].unread > 0) {
      _unread = max(0, _unread - _chats[i].unread);
      final c = _chats[i];
      _chats = [..._chats]..[i] = ChatSummary(chatId: c.chatId, kind: c.kind, title: c.title, subtitle: c.subtitle, avatarUrl: c.avatarUrl, lastAt: c.lastAt, lastPreview: c.lastPreview, lastMine: c.lastMine, crewId: c.crewId);
      _notify();
    }
    try {
      await _api.post('/chats/${Uri.encodeComponent(chatId)}/read', {'at': DateTime.now().millisecondsSinceEpoch});
    } catch (_) {}
  }

  Future<String?> deleteMessage(String chatId, String messageId) async {
    try {
      await _api.delete('/chats/${Uri.encodeComponent(chatId)}/messages/${Uri.encodeComponent(messageId)}');
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (_) {
      return 'Could not reach CoRoute. Try again.';
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _lifecycle?.dispose();
    _incoming.close();
    _deleted.close();
    _api.removeListener(_onApiChanged);
    super.dispose();
  }
}
