// Round 10 rescue beacon: the short rescue id a victim's phone sends in its near-ultrasonic
// packets and BLE locator advertisement, so a responder's phone knows WHICH rider it hears.
//
// 16 bits, derived from the SOS key both sides already know:
//  * the SOS clientId (the victim's phone makes it when the SOS is raised, also offline; the
//    gateway stores it with the alert and sends it to the group), else
//  * the server alertId (an alert raised without a clientId, e.g. by an older app).
// The gateway derives the same value (gateway/src/rescue_beacon.js) and sends it as `rescueId`
// (4 lower-case hex digits) with the alert, so responders get it with the SOS. Both sides MUST
// use the same function: FNV-1a 32 over the UTF-8 bytes, folded to 16 bits (xor of the halves),
// 0 mapped to 1 (0 means "no id").
//
// A 16-bit id is not a secret and not personal data: it only tells two nearby phones apart. Two
// open SOS alerts in the same forest share an id with a chance of 1 in 65 535.
import 'dart:convert';

class RescueId {
  RescueId._();

  /// The rescue id (1..65535) for an SOS key (clientId or alertId). 0 for an empty key.
  static int fromKey(String key) {
    if (key.isEmpty) return 0;
    var h = 0x811c9dc5;
    for (final b in utf8.encode(key)) {
      h ^= b;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    final folded = ((h >> 16) ^ (h & 0xFFFF)) & 0xFFFF;
    return folded == 0 ? 1 : folded;
  }

  /// Four lower-case hex digits ("0a3f").
  static String hex(int id) => (id & 0xFFFF).toRadixString(16).padLeft(4, '0');

  static final RegExp _hexRe = RegExp(r'^[0-9a-fA-F]{4}$');

  /// Parses "0a3f" (as the gateway sends it). Null when missing, malformed or zero.
  static int? parseHex(Object? s) {
    if (s is! String || !_hexRe.hasMatch(s)) return null;
    final v = int.parse(s, radix: 16);
    return v == 0 ? null : v;
  }

  /// The id of an alert: the server's `rescueId` when valid, else derived from the clientId,
  /// else from the alertId (the same order the gateway uses). 0 when nothing is known.
  static int forAlert({Object? rescueIdHex, String clientId = '', String alertId = ''}) {
    final given = parseHex(rescueIdHex);
    if (given != null) return given;
    if (clientId.isNotEmpty) return fromKey(clientId);
    return fromKey(alertId);
  }

  /// CRC-8 (polynomial 0x07, init 0) over the two id bytes, big-endian. Guards each acoustic
  /// packet: a random 24-bit pattern passes with a chance of 1 in 256.
  static int crc8(int id) {
    var crc = 0;
    for (final byte in [(id >> 8) & 0xFF, id & 0xFF]) {
      crc ^= byte;
      for (var i = 0; i < 8; i++) {
        crc = (crc & 0x80) != 0 ? ((crc << 1) ^ 0x07) & 0xFF : (crc << 1) & 0xFF;
      }
    }
    return crc;
  }
}
