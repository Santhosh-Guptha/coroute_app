// Round 10 rescue beacon: the BLE locator advertisement (pure Dart; RescueBeaconChannel.kt builds
// and parses the same bytes).
//
// Service data under CoRoute's own 128-bit rescue service UUID (independent of any other CoRoute
// BLE use, e.g. the offline mesh), 5 bytes:
//   [0] 0x52 ('R')  magic
//   [1] 0x01        format version
//   [2..3]          rescue id, big-endian
//   [4]             flags: bit0 siren running, bit1 battery reserve, bit2 bystander stopped the siren
// Legacy advertising (31 bytes): flags 3 + service data (2 + 16 + 5) = 26 bytes. Extended
// advertising (Android 8+, when the chip supports it) carries the same service data, on the LE
// Coded PHY when supported (longer range, about 2..4x the 1M PHY in open air).
// No name, no position, nothing personal: a passer-by's scanner sees an unknown UUID with 5 bytes.
import 'dart:typed_data';

class RescueBle {
  RescueBle._();

  static const String serviceUuid = '6f1d0c2a-5b8e-4c37-9a41-2e7c5d0b9f13';
  static const int magic = 0x52;
  static const int version = 1;

  static const int flagSiren = 0x01;
  static const int flagReserve = 0x02;
  static const int flagBystander = 0x04;

  static Uint8List payload(int rescueId, {int flags = 0}) =>
      Uint8List.fromList([magic, version, (rescueId >> 8) & 0xFF, rescueId & 0xFF, flags & 0xFF]);

  /// The rescue id in service data bytes, or null when it is not a CoRoute rescue advertisement.
  static int? parse(List<int> data) {
    if (data.length < 4 || data[0] != magic || data[1] != version) return null;
    final id = ((data[2] & 0xFF) << 8) | (data[3] & 0xFF);
    return id == 0 ? null : id;
  }
}
