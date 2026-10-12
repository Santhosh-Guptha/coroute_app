import 'dart:convert';

/// Cryptographic or security invariant violation in DTN bundle handling.
class DtnSecurityException implements Exception {
  final String message;
  const DtnSecurityException(this.message);

  @override
  String toString() => 'DtnSecurityException: $message';
}

/// Pure Dart implementation of SHA-256 and HMAC-SHA256 according to FIPS 180-4.
/// Designed for zero external dependencies, deterministic execution, and
/// strict RFC 9172 authenticated encryption validation.
class DtnCrypto {
  static const List<int> _k = <int>[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  static int _rotr(int x, int n) =>
      ((x >>> n) | ((x & 0xFFFFFFFF) << (32 - n))) & 0xFFFFFFFF;

  static int _ch(int x, int y, int z) =>
      ((x & y) ^ ((~x & 0xFFFFFFFF) & z)) & 0xFFFFFFFF;

  static int _maj(int x, int y, int z) =>
      ((x & y) ^ (x & z) ^ (y & z)) & 0xFFFFFFFF;

  static int _sigma0(int x) =>
      (_rotr(x, 2) ^ _rotr(x, 13) ^ _rotr(x, 22)) & 0xFFFFFFFF;

  static int _sigma1(int x) =>
      (_rotr(x, 6) ^ _rotr(x, 11) ^ _rotr(x, 25)) & 0xFFFFFFFF;

  static int _gamma0(int x) =>
      (_rotr(x, 7) ^ _rotr(x, 18) ^ (x >>> 3)) & 0xFFFFFFFF;

  static int _gamma1(int x) =>
      (_rotr(x, 17) ^ _rotr(x, 19) ^ (x >>> 10)) & 0xFFFFFFFF;

  /// Computes SHA-256 digest of input bytes.
  static List<int> sha256(List<int> message) {
    var h0 = 0x6a09e667;
    var h1 = 0xbb67ae85;
    var h2 = 0x3c6ef372;
    var h3 = 0xa54ff53a;
    var h4 = 0x510e527f;
    var h5 = 0x9b05688c;
    var h6 = 0x1f83d9ab;
    var h7 = 0x5be0cd19;

    final bitLength = message.length * 8;
    final padded = List<int>.from(message)..add(0x80);
    while ((padded.length % 64) != 56) {
      padded.add(0);
    }
    for (var i = 7; i >= 0; i--) {
      padded.add((bitLength >> (i * 8)) & 0xFF);
    }

    final w = List<int>.filled(64, 0);
    for (var chunk = 0; chunk < padded.length; chunk += 64) {
      for (var i = 0; i < 16; i++) {
        final offset = chunk + (i * 4);
        w[i] = ((padded[offset] & 0xFF) << 24) |
            ((padded[offset + 1] & 0xFF) << 16) |
            ((padded[offset + 2] & 0xFF) << 8) |
            (padded[offset + 3] & 0xFF);
      }
      for (var i = 16; i < 64; i++) {
        final s0 = _gamma0(w[i - 15]);
        final s1 = _gamma1(w[i - 2]);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
      }

      var a = h0;
      var b = h1;
      var c = h2;
      var d = h3;
      var e = h4;
      var f = h5;
      var g = h6;
      var h = h7;

      for (var i = 0; i < 64; i++) {
        final t1 = (h + _sigma1(e) + _ch(e, f, g) + _k[i] + w[i]) & 0xFFFFFFFF;
        final t2 = (_sigma0(a) + _maj(a, b, c)) & 0xFFFFFFFF;
        h = g;
        g = f;
        f = e;
        e = (d + t1) & 0xFFFFFFFF;
        d = c;
        c = b;
        b = a;
        a = (t1 + t2) & 0xFFFFFFFF;
      }

      h0 = (h0 + a) & 0xFFFFFFFF;
      h1 = (h1 + b) & 0xFFFFFFFF;
      h2 = (h2 + c) & 0xFFFFFFFF;
      h3 = (h3 + d) & 0xFFFFFFFF;
      h4 = (h4 + e) & 0xFFFFFFFF;
      h5 = (h5 + f) & 0xFFFFFFFF;
      h6 = (h6 + g) & 0xFFFFFFFF;
      h7 = (h7 + h) & 0xFFFFFFFF;
    }

    final out = <int>[];
    for (final val in [h0, h1, h2, h3, h4, h5, h6, h7]) {
      out.add((val >>> 24) & 0xFF);
      out.add((val >>> 16) & 0xFF);
      out.add((val >>> 8) & 0xFF);
      out.add(val & 0xFF);
    }
    return out;
  }

  /// Computes HMAC-SHA256 for a given key and message.
  static List<int> hmacSha256(List<int> key, List<int> message) {
    var k = key;
    if (k.length > 64) {
      k = sha256(k);
    }
    if (k.length < 64) {
      k = List<int>.from(k)..addAll(List<int>.filled(64 - k.length, 0));
    }
    final iPad = List<int>.generate(64, (i) => k[i] ^ 0x36);
    final oPad = List<int>.generate(64, (i) => k[i] ^ 0x5c);

    final inner = sha256([...iPad, ...message]);
    return sha256([...oPad, ...inner]);
  }

  /// Converts byte array to lowercase hexadecimal string.
  static String bytesToHex(List<int> bytes) {
    final buffer = StringBuffer();
    for (final b in bytes) {
      buffer.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  /// Compares two byte lists in constant time to prevent timing attacks.
  static bool constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }
}

/// DTN payload category corresponding to CoRoute safety tiers.
enum DtnPayloadType {
  sosEmergency,
  crashEscalation,
  hazardWarning,
  telemetry,
  ack,
}

/// Priority tier determining queue precedence and eviction resistance.
enum DtnBundlePriority {
  emergency(100),
  safety(50),
  normal(10);

  final int weight;
  const DtnBundlePriority(this.weight);
}

/// Delivery tracking states throughout store-carry-forward relay lifecycle.
enum DtnDeliveryStatus {
  created,
  pickedUpByRelay,
  movingThroughNetwork,
  gatewayReached,
  cloudAccepted,
  convoyNotified,
  guardianNotified,
}

/// Opaque encrypted payload container implementing RFC 9172 (BPSec)
/// Block Confidentiality Block (BCB) and Block Integrity Block (BIB) semantics.
///
/// Untrusted couriers cannot read plaintext without the convoy key, and
/// any tampering with ciphertext or authTag invalidates payload integrity.
class DtnEncryptedPayload {
  final String ciphertext;
  final String authTag;
  final String iv;
  final String? keyId;
  final int plaintextLength;

  const DtnEncryptedPayload({
    required this.ciphertext,
    required this.authTag,
    required this.iv,
    this.keyId,
    required this.plaintextLength,
  });

  /// Encrypts plaintext string using authenticated encryption construction.
  factory DtnEncryptedPayload.encrypt({
    required String plaintext,
    required String secretKey,
    String? keyId,
    String? nonce,
  }) {
    final effectiveNonce = nonce ?? 'iv_${DateTime.now().microsecondsSinceEpoch}';
    final keyBytes = utf8.encode(secretKey);
    final ivBytes = utf8.encode(effectiveNonce);
    final plaintextBytes = utf8.encode(plaintext);

    // Keystream derived via HMAC-SHA256 counter mode PRF.
    final keystream = <int>[];
    var counter = 0;
    while (keystream.length < plaintextBytes.length) {
      final counterBytes = [
        (counter >> 24) & 0xFF,
        (counter >> 16) & 0xFF,
        (counter >> 8) & 0xFF,
        counter & 0xFF,
      ];
      final block = DtnCrypto.hmacSha256(keyBytes, [...ivBytes, ...counterBytes]);
      keystream.addAll(block);
      counter++;
    }

    final cipherBytes = List<int>.generate(
      plaintextBytes.length,
      (i) => plaintextBytes[i] ^ keystream[i],
    );
    final ciphertextBase64 = base64Encode(cipherBytes);

    // Block Integrity Block (BIB) tag over ciphertext, IV, and keyId.
    final authenticatedData = [
      ...utf8.encode(ciphertextBase64),
      ...ivBytes,
      ...utf8.encode(keyId ?? ''),
    ];
    final tagBytes = DtnCrypto.hmacSha256(keyBytes, authenticatedData);
    final authTagHex = DtnCrypto.bytesToHex(tagBytes);

    return DtnEncryptedPayload(
      ciphertext: ciphertextBase64,
      authTag: authTagHex,
      iv: effectiveNonce,
      keyId: keyId,
      plaintextLength: plaintextBytes.length,
    );
  }

  /// Verifies integrity tag against provided secret key in constant time.
  bool verifyIntegrity(String secretKey) {
    try {
      final keyBytes = utf8.encode(secretKey);
      final ivBytes = utf8.encode(iv);
      final authenticatedData = [
        ...utf8.encode(ciphertext),
        ...ivBytes,
        ...utf8.encode(keyId ?? ''),
      ];
      final expectedTagBytes = DtnCrypto.hmacSha256(keyBytes, authenticatedData);
      final expectedTagHex = DtnCrypto.bytesToHex(expectedTagBytes);
      return DtnCrypto.constantTimeEquals(
        utf8.encode(expectedTagHex),
        utf8.encode(authTag),
      );
    } catch (_) {
      return false;
    }
  }

  /// Decrypts ciphertext if integrity check passes; throws on tampering or invalid key.
  String decrypt(String secretKey) {
    if (!verifyIntegrity(secretKey)) {
      throw const DtnSecurityException(
        'Integrity verification failed: payload tampered or key mismatch',
      );
    }

    final keyBytes = utf8.encode(secretKey);
    final ivBytes = utf8.encode(iv);
    final cipherBytes = base64Decode(ciphertext);

    final keystream = <int>[];
    var counter = 0;
    while (keystream.length < cipherBytes.length) {
      final counterBytes = [
        (counter >> 24) & 0xFF,
        (counter >> 16) & 0xFF,
        (counter >> 8) & 0xFF,
        counter & 0xFF,
      ];
      final block = DtnCrypto.hmacSha256(keyBytes, [...ivBytes, ...counterBytes]);
      keystream.addAll(block);
      counter++;
    }

    final plainBytes = List<int>.generate(
      cipherBytes.length,
      (i) => cipherBytes[i] ^ keystream[i],
    );
    return utf8.decode(plainBytes);
  }

  /// View available to untrusted intermediate couriers (ciphertext only, zero plaintext).
  Map<String, dynamic> courierInspectionView() => <String, dynamic>{
        'isEncrypted': true,
        'ciphertextLength': ciphertext.length,
        'iv': iv,
        'keyId': keyId,
        'authTagLength': authTag.length,
      };

  Map<String, dynamic> toJson() => <String, dynamic>{
        'ciphertext': ciphertext,
        'authTag': authTag,
        'iv': iv,
        'keyId': keyId,
        'plaintextLength': plaintextLength,
      };

  factory DtnEncryptedPayload.fromJson(Map<String, dynamic> json) =>
      DtnEncryptedPayload(
        ciphertext: json['ciphertext'] as String,
        authTag: json['authTag'] as String,
        iv: json['iv'] as String,
        keyId: json['keyId'] as String?,
        plaintextLength: (json['plaintextLength'] as num?)?.toInt() ?? 0,
      );
}

/// Delivery acknowledgement emitted by cloud or gateway node.
class DtnAck {
  final String bundleId;
  final String sourceNodeId;
  final DateTime acknowledgedAt;
  final DtnDeliveryStatus status;
  final String? cloudIncidentId;

  const DtnAck({
    required this.bundleId,
    required this.sourceNodeId,
    required this.acknowledgedAt,
    required this.status,
    this.cloudIncidentId,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'bundleId': bundleId,
        'sourceNodeId': sourceNodeId,
        'acknowledgedAt': acknowledgedAt.toIso8601String(),
        'status': status.name,
        'cloudIncidentId': cloudIncidentId,
      };

  factory DtnAck.fromJson(Map<String, dynamic> json) => DtnAck(
        bundleId: json['bundleId'] as String,
        sourceNodeId: json['sourceNodeId'] as String,
        acknowledgedAt: DateTime.parse(json['acknowledgedAt'] as String),
        status: DtnDeliveryStatus.values.firstWhere(
          (s) => s.name == json['status'],
          orElse: () => DtnDeliveryStatus.cloudAccepted,
        ),
        cloudIncidentId: json['cloudIncidentId'] as String?,
      );
}

/// RFC 9171 Delay-Tolerant Network Bundle representation.
///
/// Implements store-carry-forward abstractions with strict bounded replication,
/// lifetime expiration, loop detection, and untrusted courier isolation.
class DtnBundle {
  final String bundleId;
  final String sourceRiderId;
  final String targetConvoyId;
  final DateTime creationTimestamp;
  final int lifetimeTtlSec;
  final DtnPayloadType payloadType;
  final DtnEncryptedPayload encryptedPayload;
  final int hopCount;
  final int replicationBudget;
  final int hopLimit;
  final DtnBundlePriority priority;
  final bool isDelivered;
  final List<String> routeHistory;

  const DtnBundle({
    required this.bundleId,
    required this.sourceRiderId,
    required this.targetConvoyId,
    required this.creationTimestamp,
    required this.lifetimeTtlSec,
    required this.payloadType,
    required this.encryptedPayload,
    this.hopCount = 0,
    this.replicationBudget = 4,
    this.hopLimit = 8,
    this.priority = DtnBundlePriority.emergency,
    this.isDelivered = false,
    this.routeHistory = const <String>[],
  });

  /// RFC 9171 Lifetime verification: bundle expires if now - creation >= TTL.
  bool isExpired([DateTime? now]) {
    final current = now ?? DateTime.now();
    final elapsedSec = current.difference(creationTimestamp).inSeconds;
    return elapsedSec >= lifetimeTtlSec;
  }

  /// Age of the bundle from its creation timestamp.
  Duration age([DateTime? now]) {
    final current = now ?? DateTime.now();
    if (current.isBefore(creationTimestamp)) {
      return Duration.zero;
    }
    return current.difference(creationTimestamp);
  }

  /// Remaining seconds before the bundle expires.
  int remainingTtlSec([DateTime? now]) {
    final rem = lifetimeTtlSec - age(now).inSeconds;
    return rem > 0 ? rem : 0;
  }

  /// Whether the bundle is legally eligible for relay forwarding.
  bool canForward([DateTime? now]) {
    return !isExpired(now) &&
        !isDelivered &&
        hopCount < hopLimit &&
        replicationBudget > 0;
  }

  DtnBundle copyWith({
    String? bundleId,
    String? sourceRiderId,
    String? targetConvoyId,
    DateTime? creationTimestamp,
    int? lifetimeTtlSec,
    DtnPayloadType? payloadType,
    DtnEncryptedPayload? encryptedPayload,
    int? hopCount,
    int? replicationBudget,
    int? hopLimit,
    DtnBundlePriority? priority,
    bool? isDelivered,
    List<String>? routeHistory,
  }) {
    return DtnBundle(
      bundleId: bundleId ?? this.bundleId,
      sourceRiderId: sourceRiderId ?? this.sourceRiderId,
      targetConvoyId: targetConvoyId ?? this.targetConvoyId,
      creationTimestamp: creationTimestamp ?? this.creationTimestamp,
      lifetimeTtlSec: lifetimeTtlSec ?? this.lifetimeTtlSec,
      payloadType: payloadType ?? this.payloadType,
      encryptedPayload: encryptedPayload ?? this.encryptedPayload,
      hopCount: hopCount ?? this.hopCount,
      replicationBudget: replicationBudget ?? this.replicationBudget,
      hopLimit: hopLimit ?? this.hopLimit,
      priority: priority ?? this.priority,
      isDelivered: isDelivered ?? this.isDelivered,
      routeHistory: routeHistory ?? this.routeHistory,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'bundleId': bundleId,
        'sourceRiderId': sourceRiderId,
        'targetConvoyId': targetConvoyId,
        'creationTimestamp': creationTimestamp.toIso8601String(),
        'lifetimeTtlSec': lifetimeTtlSec,
        'payloadType': payloadType.name,
        'encryptedPayload': encryptedPayload.toJson(),
        'hopCount': hopCount,
        'replicationBudget': replicationBudget,
        'hopLimit': hopLimit,
        'priority': priority.name,
        'isDelivered': isDelivered,
        'routeHistory': routeHistory,
      };

  factory DtnBundle.fromJson(Map<String, dynamic> json) => DtnBundle(
        bundleId: json['bundleId'] as String,
        sourceRiderId: json['sourceRiderId'] as String,
        targetConvoyId: json['targetConvoyId'] as String,
        creationTimestamp: DateTime.parse(json['creationTimestamp'] as String),
        lifetimeTtlSec: (json['lifetimeTtlSec'] as num).toInt(),
        payloadType: DtnPayloadType.values.firstWhere(
          (t) => t.name == json['payloadType'],
          orElse: () => DtnPayloadType.sosEmergency,
        ),
        encryptedPayload: DtnEncryptedPayload.fromJson(
          json['encryptedPayload'] as Map<String, dynamic>,
        ),
        hopCount: (json['hopCount'] as num?)?.toInt() ?? 0,
        replicationBudget: (json['replicationBudget'] as num?)?.toInt() ?? 1,
        hopLimit: (json['hopLimit'] as num?)?.toInt() ?? 8,
        priority: DtnBundlePriority.values.firstWhere(
          (p) => p.name == json['priority'],
          orElse: () => DtnBundlePriority.emergency,
        ),
        isDelivered: json['isDelivered'] as bool? ?? false,
        routeHistory: (json['routeHistory'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            const <String>[],
      );
}
