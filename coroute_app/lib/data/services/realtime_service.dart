import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpException, SocketException, TlsException, WebSocketException;
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../core/config/app_config.dart';
import '../../core/constants/net_constants.dart';
import '../../core/constants/network_constants.dart';
import '../models/safety_wire.dart';

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
  /// The sender's sample rate: 16 kHz, or 8 kHz from a phone in data saver mode. Anything
  /// else is treated as 16 kHz (the player is never set up at an arbitrary rate).
  int get sampleRate {
    final r = (header['sampleRate'] as num?)?.toInt();
    return (r == AppConfig.audioSampleRate || r == AppConfig.audioSampleRateLowData) ? r! : AppConfig.audioSampleRate;
  }
}

enum RealtimeState { disconnected, connecting, connected }

/// Why the socket is not connected, as far as the phone can tell:
/// [noNetwork] (no signal, DNS fails, timeouts) or [serverUnreachable]
/// (the internet works but the CoRoute server does not answer properly).
/// [none] while connected or when nothing is known yet.
enum LinkProblem { none, noNetwork, serverUnreachable }

/// The one and only WebSocket to the gateway.
///
/// Design goals: a single socket per app (battery), automatic reconnect with
/// backoff, automatic re-JOIN of the active convoy after a reconnect, and a
/// hard guarantee that no event or audio frame from a previous group is ever
/// delivered after [leaveRoom]: the gateway enforces membership, and this
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

  // ------------------------------------------------- features and link state
  Set<String> _features = const <String>{};
  LinkProblem _linkProblem = LinkProblem.none;
  int _unreachableFailures = 0;
  Map<String, dynamic>? _joinExtras;
  bool _helloOnChannel = false;
  bool _readyOnChannel = false;
  bool _failureNoted = false;
  int _channelSeq = 0;

  /// Features the gateway announced in its last HELLO; empty before that and on older gateways.
  Set<String> get serverFeatures => _features;

  /// True when the connected gateway supports [feature] (see ProtocolFeatures).
  bool supports(String feature) => _features.contains(feature);

  /// Why the link is down (notifies on change).
  LinkProblem get linkProblem => _linkProblem;

  /// The internet works but the CoRoute server did not answer (after
  /// [NetConstants.serverUnreachableAfter] such failures in a row).
  bool get serverUnreachable => _linkProblem == LinkProblem.serverUnreachable;

  /// Sorts a failed connect into "no network" or "server not reachable".
  @visibleForTesting
  static LinkProblem classify(Object error) {
    Object e = error;
    if (e is WebSocketChannelException && e.inner != null) e = e.inner!;
    if (e is TimeoutException) return LinkProblem.noNetwork;
    // An HTTP answer that is not a WebSocket upgrade (for example the proxy's 502/503).
    if (e is WebSocketException || e is HttpException) return LinkProblem.serverUnreachable;
    if (e is SocketException) {
      final code = e.osError?.errorCode;
      final text = '${e.message} ${e.osError?.message ?? ''}'.toLowerCase();
      // ECONNREFUSED: Linux/Android 111, macOS/iOS 61, Windows 10061.
      if (text.contains('refused') || code == 111 || code == 61 || code == 10061) return LinkProblem.serverUnreachable;
      return LinkProblem.noNetwork; // host lookup failed, ENETUNREACH, timed out, reset
    }
    if (e is TlsException) return LinkProblem.noNetwork; // captive portal, wrong clock
    final text = e.toString().toLowerCase();
    if (text.contains('not upgraded') || text.contains('connection refused')) return LinkProblem.serverUnreachable;
    return LinkProblem.noNetwork;
  }

  void _noteConnectFailure(LinkProblem p) {
    if (p == LinkProblem.serverUnreachable) {
      _unreachableFailures++;
      if (_unreachableFailures >= NetConstants.serverUnreachableAfter) _setLink(LinkProblem.serverUnreachable);
    } else {
      _unreachableFailures = 0;
      _setLink(LinkProblem.noNetwork);
    }
  }

  void _setLink(LinkProblem p) {
    if (_linkProblem == p) return;
    _linkProblem = p;
    notifyListeners();
  }

  /// Test hooks: a fake socket sink and incoming frames (no network in unit tests).
  @visibleForTesting
  void Function(String json)? debugSink;

  @visibleForTesting
  void debugReceive(Object data) => _onData(data);

  @visibleForTesting
  void debugConnectFailed(Object error) => _noteConnectFailure(classify(error));

  // ------------------------------------------------------------ lifecycle
  /// Called when the gateway refused the socket's account (close code 4401: signed out or
  /// deleted, 4403: on hold or blocked). The app then asks the server whether the session
  /// is really over.
  VoidCallback? onAuthRejected;

  /// Close codes the gateway uses for a refused account.
  static const int closeSignedOut = 4401;
  static const int closeAccountRefused = 4403;

  /// True after a 4403 close: no reconnect until a new token is set (retrying would only
  /// be refused again and cost battery).
  bool _refused = false;
  bool get isRefused => _refused;

  /// Decides what a socket close means: whether to tell the app, and whether to reconnect.
  @visibleForTesting
  static ({bool authRejected, bool reconnect}) closeOutcome(int? closeCode) {
    if (closeCode == closeAccountRefused) return (authRejected: true, reconnect: false);
    if (closeCode == closeSignedOut) return (authRejected: true, reconnect: true);
    return (authRejected: false, reconnect: true);
  }

  /// Use a refreshed token for the next (re)connect; the open socket stays as it is.
  void updateToken(String? token) {
    if (token == null || token.isEmpty || token == _token) return;
    _token = token;
    if (_refused) {
      _refused = false;
      _attempt = 0;
      _scheduleReconnect();
    }
  }

  void connect(String token, {bool adminMode = false}) {
    _token = token;
    _adminMode = adminMode;
    _wantConnection = true;
    _refused = false;
    _attempt = 0;
    _open();
  }

  void disconnect() {
    _wantConnection = false;
    _groupId = null;
    _joinExtras = null;
    _unreachableFailures = 0;
    _linkProblem = LinkProblem.none;
    _reconnectTimer?.cancel();
    _staleTimer?.cancel();
    _closeChannel();
    _setState(RealtimeState.disconnected);
  }

  /// Binds this socket to a convoy. Any previous room is left first.
  /// [prevExit] / [prevAliveAt] ("the app was killed last time") go with the next JOIN only,
  /// and only to a gateway that supports presence.
  void joinRoom(String groupId, {String? prevExit, int? prevAliveAt}) {
    if (_groupId != null && _groupId != groupId) _send({'type': 'LEAVE'});
    _groupId = groupId;
    if (prevExit != null) _joinExtras = {'prevExit': prevExit, 'prevAliveAt': ?prevAliveAt};
    if (isConnected) _sendJoin();
  }

  void _sendJoin() {
    final gid = _groupId;
    if (gid == null) return;
    final msg = <String, dynamic>{'type': 'JOIN', 'groupId': gid};
    final extras = _joinExtras;
    if (extras != null && supports(ProtocolFeatures.presence)) msg.addAll(extras);
    // 3.15: say what this app understands, on every JOIN, only to a gateway that has the safety network.
    if (supports(ProtocolFeatures.safetyNet)) msg['caps'] = List<String>.of(NetworkConstants.clientCaps);
    if (_send(msg)) _joinExtras = null;
  }

  void leaveRoom({bool leaveConvoy = false}) {
    _joinExtras = null;
    if (_groupId == null) return;
    _send({'type': 'LEAVE', 'leaveConvoy': leaveConvoy});
    _groupId = null;
  }

  /// Tells the gateway this close is on purpose (APP_CLOSED, SIGN_OUT or LEFT), so the
  /// group sees "App closed" instead of "No signal". Only to a gateway that supports it.
  bool sendBye(String reason) {
    if (!supports(ProtocolFeatures.presence)) return false;
    return _send({'type': 'BYE', 'reason': reason});
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
    final sink = debugSink;
    if (sink != null) {
      sink(jsonEncode(message));
      return true;
    }
    try {
      _channel?.sink.add(jsonEncode(message));
      return true;
    } catch (e) {
      debugPrint('ws send note: $e');
      return false;
    }
  }

  /// Sends a compact 24-byte binary telemetry frame (REQ-06) if connected.
  bool sendBinaryTelemetry({
    required int timestampMs,
    required double lat,
    required double lng,
    required double speedKmh,
    required double heading,
    required int batteryLevel,
    required bool isCharging,
    required int usableFuelKm,
    required bool stopped,
    required bool offRoute,
    required bool sos,
    required bool tunnel,
    int sequence = 0,
  }) {
    if (!isConnected || _groupId == null) return false;
    final data = ByteData(24);
    data.setUint8(0, 0x10); // Frame type TELEMETRY_V2
    data.setUint32(1, timestampMs & 0xFFFFFFFF, Endian.big);
    data.setInt32(5, (lat * 1e6).round(), Endian.big);
    data.setInt32(9, (lng * 1e6).round(), Endian.big);
    data.setUint16(13, (speedKmh * 10).round().clamp(0, 65535), Endian.big);
    data.setUint16(15, (heading * 10).round().clamp(0, 3600), Endian.big);
    final bat = (batteryLevel.clamp(0, 100)) | (isCharging ? 0x80 : 0);
    data.setUint8(17, bat);
    data.setUint8(18, (usableFuelKm ~/ 2).clamp(0, 255));
    var flags = 0;
    if (stopped) flags |= 0x01;
    if (offRoute) flags |= 0x02;
    if (sos) flags |= 0x04;
    if (tunnel) flags |= 0x08;
    data.setUint8(19, flags);
    data.setUint32(20, sequence & 0xFFFFFFFF, Endian.big);

    final bytes = data.buffer.asUint8List();
    final sink = debugSink;
    if (sink != null) {
      sink(jsonEncode({'type': 'BINARY_TELEMETRY', 'bytes': bytes.length}));
      return true;
    }
    try {
      _channel?.sink.add(bytes);
      return true;
    } catch (e) {
      debugPrint('ws sendBinaryTelemetry note: $e');
      return false;
    }
  }

  // ------------------------------------------------------------ internals
  void _open() {
    if (!_wantConnection || _token == null || _refused) return;
    _closeChannel();
    _setState(RealtimeState.connecting);
    try {
      final uri = Uri.parse('${AppConfig.wsUrl}?token=${Uri.encodeQueryComponent(_token!)}');
      final ch = WebSocketChannel.connect(uri);
      _channel = ch;
      final seq = ++_channelSeq;
      _helloOnChannel = false;
      _readyOnChannel = false;
      _failureNoted = false;
      ch.ready.then((_) {
        if (seq == _channelSeq) _readyOnChannel = true;
      }, onError: (Object e) {
        if (seq != _channelSeq || _failureNoted) return;
        _failureNoted = true;
        _noteConnectFailure(classify(e));
      });
      _sub = ch.stream.listen(_onData, onError: (_) => _scheduleReconnect(), onDone: () {
        // Connected at the TCP/TLS level, then closed before HELLO: the server is not answering properly.
        if (seq == _channelSeq && _readyOnChannel && !_helloOnChannel && !_failureNoted && ch.closeCode != closeSignedOut && ch.closeCode != closeAccountRefused) {
          _failureNoted = true;
          _noteConnectFailure(LinkProblem.serverUnreachable);
        }
        final outcome = closeOutcome(ch.closeCode);
        if (!outcome.reconnect) {
          _refused = true;
          _reconnectTimer?.cancel();
          _staleTimer?.cancel();
          _closeChannel();
          _setState(RealtimeState.disconnected);
        }
        if (outcome.authRejected) onAuthRejected?.call();
        if (outcome.reconnect) _scheduleReconnect();
      }, cancelOnError: true);
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
        _helloOnChannel = true;
        final f = msg['features'];
        _features = f is List ? <String>{for (final x in f) x.toString()} : const <String>{};
        _unreachableFailures = 0;
        final linkChanged = _linkProblem != LinkProblem.none;
        final wasConnected = isConnected;
        _linkProblem = LinkProblem.none;
        _setState(RealtimeState.connected);
        if (linkChanged && wasConnected) notifyListeners();
        if (_groupId != null) _sendJoin();
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
        'SOS_RESPONSE', 'PRESENCE', 'ROSTER_CHANGED',
        // 3.15 safety and discovery networks.
        'EMERGENCY_UPDATE', 'ASSIST_REQUEST', 'ASSIST_UPDATE', 'ASSIST_CLOSED', 'HAZARD', 'HAZARD_CLEAR', 'DISCOVERY', 'WAVED',
      };
      if (roomScoped.contains(type) && _groupId == null) return;
      if (type == 'SNAPSHOT' && msg['convoy'] is Map && msg['convoy']['groupId'] != _groupId) return;
      _events.add(msg);
      return;
    }
    if (data is List<int>) {
      if (_groupId == null) return; // audio for a room we already left
      final bytes = data is Uint8List ? data : Uint8List.fromList(data);
      if (bytes.isNotEmpty && bytes[0] == 0x10) {
        final telemetryMsg = _decodeBinaryTelemetry(bytes);
        if (telemetryMsg != null) _events.add(telemetryMsg);
        return;
      }
      final pkt = _decodeVoice(bytes);
      if (pkt != null) _voice.add(pkt);
    }
  }

  Map<String, dynamic>? _decodeBinaryTelemetry(Uint8List buf) {
    if (buf.length < 24) return null;
    final view = ByteData.sublistView(buf);
    final lat = view.getInt32(5, Endian.big) / 1e6;
    final lng = view.getInt32(9, Endian.big) / 1e6;
    final speedKmh = view.getUint16(13, Endian.big) / 10.0;
    final heading = view.getUint16(15, Endian.big) / 10.0;
    final batByte = view.getUint8(17);
    final batteryLevel = batByte & 0x7F;
    final isCharging = (batByte & 0x80) != 0;
    final fuelKm = view.getUint8(18) * 2;
    final flags = view.getUint8(19);
    final stopped = (flags & 0x01) != 0;
    final offRoute = (flags & 0x02) != 0;
    final sos = (flags & 0x04) != 0;
    final tunnel = (flags & 0x08) != 0;

    return {
      'type': 'RIDER_UPDATE',
      'rider': {
        'lat': lat,
        'lng': lng,
        'speedKmh': speedKmh,
        'heading': heading,
        'batteryLevel': batteryLevel,
        'isCharging': isCharging,
        'fuelKm': fuelKm,
        'stoppedSince': stopped ? DateTime.now().millisecondsSinceEpoch : 0,
        'statusReason': sos ? 'SOS' : (offRoute ? 'OFF_ROUTE' : null),
        'trackingConfidence': tunnel ? 'tunnelCoasting' : 'gpsFix',
      },
    };
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
    if (!_wantConnection || _refused) return;
    if (_reconnectTimer?.isActive == true) return;
    _closeChannel();
    _setState(RealtimeState.disconnected);
    // 1s, 2s, 4s ... capped at 30s, with jitter, gentle on battery and server.
    final base = math.min(30000, 1000 * math.pow(2, math.min(_attempt, 5)).toInt());
    final jitter = math.Random().nextInt(500);
    _attempt++;
    _reconnectTimer = Timer(Duration(milliseconds: base + jitter), _open);
  }

  void _closeChannel() {
    // A late `ready` error of a closed channel must not touch the link state (or a disposed service).
    _channelSeq++;
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
