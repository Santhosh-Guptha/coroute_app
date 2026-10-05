import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../core/config/app_config.dart';

/// Binary voice packet kinds (must match gateway/src/ws.js).
class VoiceKind {
  static const int start = 0x01;
  static const int frame = 0x02;
  static const int end = 0x03;
}

/// A decoded voice packet received from the gateway.
class VoicePacket {
  final int kind;
  final Map<String, dynamic> header;
  final Uint8List payload;
  const VoicePacket(this.kind, this.header, this.payload);

  String get streamId => header['streamId']?.toString() ?? '';
  String get from => header['from']?.toString() ?? '';
  String get fromName => header['fromName']?.toString() ?? 'Rider';
  String? get to => header['to']?.toString();
  bool get isPrivate => to != null && to!.isNotEmpty;
  int get sampleRate => (header['sampleRate'] as num?)?.toInt() ?? AppConfig.audioSampleRate;
}

enum RealtimeState { disconnected, connecting, connected }

/// The one and only WebSocket to the gateway.
///
/// Design goals: a single socket per app (battery), automatic reconnect with
/// backoff, automatic re-JOIN of the active convoy after a reconnect, and a
/// hard guarantee that no event or audio frame from a previous group is ever
/// delivered after [leaveRoom] — the gateway enforces membership, and this
/// class additionally drops anything that is not for the current room.
class RealtimeService extends ChangeNotifier {
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _reconnectTimer;
  Timer? _staleTimer;
  int _attempt = 0;
  bool _wantConnection = false;
  bool _adminMode = false;
  String? _token;
  String? _groupId;
  RealtimeState _state = RealtimeState.disconnected;
  DateTime _lastMessageAt = DateTime.now();

  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _voice = StreamController<VoicePacket>.broadcast();

  Stream<Map<String, dynamic>> get events => _events.stream;
  Stream<VoicePacket> get voice => _voice.stream;
  RealtimeState get state => _state;
  bool get isConnected => _state == RealtimeState.connected;
  String? get groupId => _groupId;

  // ------------------------------------------------------------ lifecycle
  void connect(String token, {bool adminMode = false}) {
    _token = token;
    _adminMode = adminMode;
    _wantConnection = true;
    _attempt = 0;
    _open();
  }

  void disconnect() {
    _wantConnection = false;
    _groupId = null;
    _reconnectTimer?.cancel();
    _staleTimer?.cancel();
    _closeChannel();
    _setState(RealtimeState.disconnected);
  }

  /// Binds this socket to a convoy. Any previous room is left first.
  void joinRoom(String groupId) {
    if (_groupId != null && _groupId != groupId) _send({'type': 'LEAVE'});
    _groupId = groupId;
    if (isConnected) _send({'type': 'JOIN', 'groupId': groupId});
  }

  void leaveRoom({bool leaveConvoy = false}) {
    if (_groupId == null) return;
    _send({'type': 'LEAVE', 'leaveConvoy': leaveConvoy});
    _groupId = null;
  }

  // ------------------------------------------------------------- sending
  /// Sends a JSON command for the current room. Silently dropped when offline.
  bool send(Map<String, dynamic> message) => _send(message);

  /// Sends a voice packet (binary). Dropped when offline or not in a room.
  void sendVoice(int kind, Map<String, dynamic> header, [Uint8List? payload]) {
    if (!isConnected || _groupId == null) return;
    final h = utf8.encode(jsonEncode(header));
    final out = Uint8List(3 + h.length + (payload?.length ?? 0));
    out[0] = kind;
    out[1] = (h.length >> 8) & 0xff;
    out[2] = h.length & 0xff;
    out.setRange(3, 3 + h.length, h);
    if (payload != null) out.setRange(3 + h.length, out.length, payload);
    try {
      _channel?.sink.add(out);
    } catch (e) {
      debugPrint('ws sendVoice note: $e');
    }
  }

  bool _send(Map<String, dynamic> message) {
    if (!isConnected) return false;
    try {
      _channel?.sink.add(jsonEncode(message));
      return true;
    } catch (e) {
      debugPrint('ws send note: $e');
      return false;
    }
  }

  // ------------------------------------------------------------ internals
  void _open() {
    if (!_wantConnection || _token == null) return;
    _closeChannel();
    _setState(RealtimeState.connecting);
    try {
      final uri = Uri.parse('${AppConfig.wsUrl}?token=${Uri.encodeQueryComponent(_token!)}');
      final ch = WebSocketChannel.connect(uri);
      _channel = ch;
      _sub = ch.stream.listen(_onData, onError: (_) => _scheduleReconnect(), onDone: _scheduleReconnect, cancelOnError: true);
      _lastMessageAt = DateTime.now();
      _staleTimer?.cancel();
      _staleTimer = Timer.periodic(const Duration(seconds: 40), (_) {
        // The gateway pings every 30 s; if nothing arrived for 100 s the link is dead.
        if (DateTime.now().difference(_lastMessageAt).inSeconds > 100) _scheduleReconnect();
      });
    } catch (e) {
      debugPrint('ws connect note: $e');
      _scheduleReconnect();
    }
  }

  void _onData(dynamic data) {
    _lastMessageAt = DateTime.now();
    if (data is String) {
      Map<String, dynamic> msg;
      try {
        final decoded = jsonDecode(data);
        if (decoded is! Map) return;
        msg = Map<String, dynamic>.from(decoded);
      } catch (_) {
        return;
      }
      final type = msg['type']?.toString();
      if (type == 'HELLO') {
        _attempt = 0;
        _setState(RealtimeState.connected);
        if (_groupId != null) _send({'type': 'JOIN', 'groupId': _groupId});
        if (_adminMode) _send({'type': 'ADMIN_SUBSCRIBE'});
        return;
      }
      if (type == 'PONG') return;
      // Room-scoped events carry no groupId by design (the socket is bound to a
      // room server-side). Drop them if we have since left the room.
      const roomScoped = {
        'SNAPSHOT', 'RIDER_UPDATE', 'RIDER_LEFT', 'MESSAGE', 'ALERT', 'ALERT_RESOLVED', 'STOPS',
        'WAIT_REQUESTS', 'CONFIG', 'TRIP_STATUS', 'DISSOLVED', 'VOICE_BUSY',
        'TIMELINE', 'TIMELINE_UPDATE', 'TIMELINE_BATCH', 'REPORT_READY',
      };
      if (roomScoped.contains(type) && _groupId == null) return;
      if (type == 'SNAPSHOT' && msg['convoy'] is Map && msg['convoy']['groupId'] != _groupId) return;
      _events.add(msg);
      return;
    }
    if (data is List<int>) {
      if (_groupId == null) return; // audio for a room we already left
      final bytes = data is Uint8List ? data : Uint8List.fromList(data);
      final pkt = _decodeVoice(bytes);
      if (pkt != null) _voice.add(pkt);
    }
  }

  VoicePacket? _decodeVoice(Uint8List buf) {
    if (buf.length < 3) return null;
    final kind = buf[0];
    final hl = (buf[1] << 8) | buf[2];
    if (hl > 2048 || buf.length < 3 + hl) return null;
    try {
      final header = Map<String, dynamic>.from(jsonDecode(utf8.decode(buf.sublist(3, 3 + hl))) as Map);
      return VoicePacket(kind, header, Uint8List.sublistView(buf, 3 + hl));
    } catch (_) {
      return null;
    }
  }

  void _scheduleReconnect() {
    if (!_wantConnection) return;
    if (_reconnectTimer?.isActive == true) return;
    _closeChannel();
    _setState(RealtimeState.disconnected);
    // 1s, 2s, 4s ... capped at 30s, with jitter — gentle on battery and server.
    final base = math.min(30000, 1000 * math.pow(2, math.min(_attempt, 5)).toInt());
    final jitter = math.Random().nextInt(500);
    _attempt++;
    _reconnectTimer = Timer(Duration(milliseconds: base + jitter), _open);
  }

  void _closeChannel() {
    _sub?.cancel();
    _sub = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }

  void _setState(RealtimeState s) {
    if (_state == s) return;
    _state = s;
    notifyListeners();
  }

  @override
  void dispose() {
    disconnect();
    _events.close();
    _voice.close();
    super.dispose();
  }
}
