// Round 8: the separate voice socket (gateway VOICE_RELAY_MODE=process; docs/features_355/voice_clarity.md).
// The gateway hands out a short-lived ticket in VOICE_CODEC.voice; this phone then opens wss://host/voice,
// authenticates with the ticket as its first message (never in the URL), and sends / receives intercom frames
// there, so voice never shares the live socket with SOS and positions. Everything else stays on /ws.
// When this socket is down the intercom simply uses /ws (as on an in-process gateway).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../../core/config/app_config.dart';
import '../realtime_service.dart' show VoicePacket;

class VoiceLink {
  VoiceLink({this.urlFor});

  /// Builds the voice URL from the gateway's /ws URL (tests may override).
  final String Function(String path)? urlFor;

  WebSocketChannel? _ch;
  StreamSubscription<dynamic>? _sub;
  bool _ready = false;
  bool _closedByUs = false;
  String? _groupId;
  final StreamController<VoicePacket> _packets = StreamController<VoicePacket>.broadcast();

  /// Called when the socket became ready (true) or dropped (false).
  void Function(bool ready)? onState;

  bool get isReady => _ready;
  String? get groupId => _groupId;
  Stream<VoicePacket> get packets => _packets.stream;

  static String defaultUrl(String path) {
    final ws = AppConfig.wsUrl;
    final p = path.startsWith('/') ? path : '/$path';
    return ws.endsWith('/ws') ? '${ws.substring(0, ws.length - 3)}$p' : ws.replaceFirst(RegExp(r'/[^/]*$'), p);
  }

  /// Opens the voice socket for [groupId] with [ticket] (replaces an open one).
  void connect({required String path, required String ticket, required String groupId}) {
    close();
    _closedByUs = false;
    _groupId = groupId;
    try {
      final ch = WebSocketChannel.connect(Uri.parse((urlFor ?? defaultUrl)(path)), protocols: const ['coroute.voice.v1']);
      _ch = ch;
      ch.sink.add(jsonEncode({'type': 'AUTH', 'ticket': ticket}));
      _sub = ch.stream.listen(_onData, onDone: _onDown, onError: (Object _) => _onDown(), cancelOnError: true);
    } catch (_) {
      _onDown();
    }
  }

  void _onData(dynamic data) {
    if (data is String) {
      try {
        final m = jsonDecode(data);
        if (m is Map && m['type'] == 'VOICE_READY') {
          _ready = true;
          onState?.call(true);
        }
      } catch (_) {}
      return;
    }
    if (data is List<int>) {
      final p = decode(data is Uint8List ? data : Uint8List.fromList(data));
      if (p != null && !_packets.isClosed) _packets.add(p);
    }
  }

  void _onDown() {
    final was = _ready;
    _ready = false;
    _sub?.cancel();
    _sub = null;
    _ch = null;
    if (was || !_closedByUs) onState?.call(false);
  }

  /// Sends one encoded voice packet; false when the socket is not ready (use /ws then).
  bool send(Uint8List bytes) {
    if (!_ready || _ch == null) return false;
    try {
      _ch!.sink.add(bytes);
      return true;
    } catch (_) {
      return false;
    }
  }

  void close() {
    _closedByUs = true;
    _ready = false;
    _sub?.cancel();
    _sub = null;
    try {
      _ch?.sink.close();
    } catch (_) {}
    _ch = null;
  }

  void dispose() {
    close();
    _packets.close();
  }

  /// The binary voice packet (same layout as RealtimeService.sendVoice / gateway src/voice_relay.js).
  static Uint8List encode(int kind, Map<String, dynamic> header, [Uint8List? payload]) {
    final h = utf8.encode(jsonEncode(header));
    final out = Uint8List(3 + h.length + (payload?.length ?? 0));
    out[0] = kind;
    out[1] = (h.length >> 8) & 0xff;
    out[2] = h.length & 0xff;
    out.setRange(3, 3 + h.length, h);
    if (payload != null) out.setRange(3 + h.length, out.length, payload);
    return out;
  }

  static VoicePacket? decode(Uint8List b) {
    if (b.length < 3) return null;
    final hl = (b[1] << 8) | b[2];
    if (hl > 2048 || b.length < 3 + hl) return null;
    try {
      final h = jsonDecode(utf8.decode(Uint8List.sublistView(b, 3, 3 + hl)));
      if (h is! Map) return null;
      return VoicePacket(b[0], Map<String, dynamic>.from(h), Uint8List.sublistView(b, 3 + hl));
    } catch (_) {
      return null;
    }
  }
}
