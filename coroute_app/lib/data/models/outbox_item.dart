import 'dart:convert';

/// Where an outbox item is: [waiting] for signal, [sending] (handed to the
/// socket, waiting for the server's ACK) or [failed] (the server refused it).
enum OutboxState { waiting, sending, failed }

/// A chat message, status card, stop arrival, WAIT request, SOS reply or
/// check-in that is kept on the phone until the server has it (B4).
class OutboxItem {
  final String clientId;
  final String groupId;

  /// The socket message type: CHAT, WAIT, STATUS, STOP_VISITED, SOS_RESPOND or CHECK_IN.
  final String type;
  final Map<String, dynamic> payload;
  final int createdAt;
  final OutboxState state;

  /// Why the server refused it (only for [OutboxState.failed]).
  final String? error;

  /// When it was refused (epoch ms; only for [OutboxState.failed]).
  final int? failedAt;

  const OutboxItem({
    required this.clientId,
    required this.groupId,
    required this.type,
    required this.payload,
    required this.createdAt,
    this.state = OutboxState.waiting,
    this.error,
    this.failedAt,
  });

  bool get isFailed => state == OutboxState.failed;

  /// Waiting for signal or for the server's answer ("Waiting for signal" in the UI).
  bool get isPending => state != OutboxState.failed;

  OutboxItem copyWith({OutboxState? state, String? error, int? failedAt}) => OutboxItem(
        clientId: clientId,
        groupId: groupId,
        type: type,
        payload: payload,
        createdAt: createdAt,
        state: state ?? this.state,
        error: error ?? this.error,
        failedAt: failedAt ?? this.failedAt,
      );

  /// The socket message: payload + type + clientId. [withClientId] false gives
  /// the 3.13 form for an older gateway (no clientId, no sentAt).
  Map<String, dynamic> toMessage({bool withClientId = true}) {
    final m = <String, dynamic>{...payload, 'type': type};
    if (withClientId) {
      m['clientId'] = clientId;
    } else {
      m.remove('sentAt');
    }
    return m;
  }

  Map<String, dynamic> toJson() => {
        'clientId': clientId,
        'groupId': groupId,
        'type': type,
        'payload': payload,
        'createdAt': createdAt,
        'state': state.name,
        'error': ?error,
        'failedAt': ?failedAt,
      };

  static OutboxItem? fromJson(Object? json) {
    if (json is! Map) return null;
    final clientId = json['clientId']?.toString() ?? '';
    final groupId = json['groupId']?.toString() ?? '';
    final type = json['type']?.toString() ?? '';
    if (clientId.isEmpty || groupId.isEmpty || type.isEmpty) return null;
    final p = json['payload'];
    final stateName = json['state']?.toString();
    return OutboxItem(
      clientId: clientId,
      groupId: groupId,
      type: type,
      payload: p is Map ? Map<String, dynamic>.from(p) : <String, dynamic>{},
      createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
      state: OutboxState.values.firstWhere((s) => s.name == stateName, orElse: () => OutboxState.waiting),
      error: json['error']?.toString(),
      failedAt: (json['failedAt'] as num?)?.toInt(),
    );
  }

  static String encodeList(List<OutboxItem> items) => jsonEncode([for (final i in items) i.toJson()]);

  static List<OutboxItem> decodeList(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return list.map(OutboxItem.fromJson).whereType<OutboxItem>().toList();
    } catch (_) {
      return const [];
    }
  }
}
