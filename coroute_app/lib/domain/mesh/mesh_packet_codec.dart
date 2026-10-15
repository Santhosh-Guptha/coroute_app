import 'dart:convert';
import 'dart:typed_data';
import 'mesh_telemetry_packet.dart';

/// Ultra-compact binary codec for transmitting telemetry and SOS distress beacons
/// over low-bandwidth offline wireless channels (UDP broadcast / BLE advertisement frames).
class MeshPacketCodec {
  MeshPacketCodec._();

  static const int minPacketSize = 32;

  /// Encodes a [MeshTelemetryPacket] into an ultra-compact binary byte array.
  static Uint8List encode(MeshTelemetryPacket packet) {
    final userBytes = utf8.encode(packet.userId);
    final nameBytes = utf8.encode(packet.userName);
    final userLen = userBytes.length.clamp(0, 48);
    final nameLen = nameBytes.length.clamp(0, 32);

    // Fixed header length = 2 (magic) + 1 (ver) + 2 (hash) + 1 (ttl/hops) + 2 (seq)
    // + 6 (timestamp) + 4 (lat) + 4 (lng) + 1 (speed) + 1 (heading) + 1 (battery)
    // + 1 (flags) + 2 (fuel) + 1 (userLen) + userLen + 1 (nameLen) + nameLen + 2 (crc)
    final totalSize = 28 + 1 + userLen + 1 + nameLen + 2;
    final bytes = Uint8List(totalSize);
    final bd = ByteData.sublistView(bytes);

    var offset = 0;
    // 1. Magic & Version
    bytes[offset++] = MeshTelemetryPacket.magicByte1;
    bytes[offset++] = MeshTelemetryPacket.magicByte2;
    bytes[offset++] = packet.version & 0xFF;

    // 2. Join Code Hash
    bd.setUint16(offset, packet.joinCodeHash & 0xFFFF, Endian.big);
    offset += 2;

    // 3. TTL & HopCount (4 bits each)
    bytes[offset++] = (packet.ttl.clamp(0, 15) & 0x0F) | ((packet.hopCount.clamp(0, 15) & 0x0F) << 4);

    // 4. Sequence number
    bd.setUint16(offset, packet.seq & 0xFFFF, Endian.big);
    offset += 2;

    // 5. 48-bit timestamp (epoch ms)
    final ts = packet.timestampMs;
    bd.setUint16(offset, ((ts >> 32) & 0xFFFF), Endian.big);
    offset += 2;
    bd.setUint32(offset, (ts & 0xFFFFFFFF), Endian.big);
    offset += 4;

    // 6. Coordinates (microdegrees)
    bd.setInt32(offset, (packet.lat * 1e6).round(), Endian.big);
    offset += 4;
    bd.setInt32(offset, (packet.lng * 1e6).round(), Endian.big);
    offset += 4;

    // 7. Speed & Heading
    bytes[offset++] = packet.speedKmh.clamp(0, 255).round();
    bytes[offset++] = ((packet.heading.clamp(0, 360) / 360.0) * 255.0).round() & 0xFF;

    // 8. Battery & Charging
    bytes[offset++] = (packet.batteryLevel.clamp(0, 100) & 0x7F) | (packet.isCharging ? 0x80 : 0);

    // 9. Flags (Role, SOS, SOSType)
    final roleInt = switch (packet.role.toUpperCase()) {
      'LEAD' => 1,
      'SWEEPER' => 2,
      _ => 0, // PACK
    };
    final sosTypeInt = switch (packet.sosType.toUpperCase()) {
      'BREAKDOWN' => 1,
      'MEDICAL' => 2,
      'STOPPED' => 3,
      'CUSTOM' => 4,
      _ => 0, // CRASH
    };
    var flags = (roleInt & 0x03);
    if (packet.isSos) flags |= 0x04;
    flags |= (sosTypeInt & 0x07) << 3;
    bytes[offset++] = flags;

    // 10. Fuel remaining (0xFFFF if null)
    final fuelVal = packet.fuelUsableKm != null ? packet.fuelUsableKm!.clamp(0, 65534).round() : 0xFFFF;
    bd.setUint16(offset, fuelVal, Endian.big);
    offset += 2;

    // 11. UserId
    bytes[offset++] = userLen;
    bytes.setRange(offset, offset + userLen, userBytes.take(userLen));
    offset += userLen;

    // 12. UserName
    bytes[offset++] = nameLen;
    bytes.setRange(offset, offset + nameLen, nameBytes.take(nameLen));
    offset += nameLen;

    // 13. Checksum (CRC-16 over all bytes up to here)
    final crc = computeCrc16(bytes, 0, offset);
    bd.setUint16(offset, crc, Endian.big);

    return bytes;
  }

  /// Decodes a binary byte array into a [MeshTelemetryPacket].
  /// Returns null if magic bytes, length, or checksum verification fails.
  static MeshTelemetryPacket? decode(Uint8List bytes) {
    if (bytes.length < minPacketSize) return null;

    // 1. Check Magic Bytes
    if (bytes[0] != MeshTelemetryPacket.magicByte1 || bytes[1] != MeshTelemetryPacket.magicByte2) {
      return null;
    }

    // 2. Verify Checksum
    final bd = ByteData.sublistView(bytes);
    final packetCrc = bd.getUint16(bytes.length - 2, Endian.big);
    final computedCrc = computeCrc16(bytes, 0, bytes.length - 2);
    if (packetCrc != computedCrc) return null;

    var offset = 2;
    final version = bytes[offset++];
    if (version != MeshTelemetryPacket.currentVersion) return null;

    final joinCodeHash = bd.getUint16(offset, Endian.big);
    offset += 2;

    final ttlHops = bytes[offset++];
    final ttl = ttlHops & 0x0F;
    final hopCount = (ttlHops >> 4) & 0x0F;

    final seq = bd.getUint16(offset, Endian.big);
    offset += 2;

    final tsHigh = bd.getUint16(offset, Endian.big);
    offset += 2;
    final tsLow = bd.getUint32(offset, Endian.big);
    offset += 4;
    final timestampMs = (tsHigh << 32) | tsLow;

    final lat = bd.getInt32(offset, Endian.big) / 1e6;
    offset += 4;
    final lng = bd.getInt32(offset, Endian.big) / 1e6;
    offset += 4;

    final speedKmh = bytes[offset++].toDouble();
    final heading = (bytes[offset++] / 255.0) * 360.0;

    final batVal = bytes[offset++];
    final batteryLevel = batVal & 0x7F;
    final isCharging = (batVal & 0x80) != 0;

    final flags = bytes[offset++];
    final roleInt = flags & 0x03;
    final role = switch (roleInt) {
      1 => 'LEAD',
      2 => 'SWEEPER',
      _ => 'PACK',
    };
    final isSos = (flags & 0x04) != 0;
    final sosTypeInt = (flags >> 3) & 0x07;
    final sosType = switch (sosTypeInt) {
      1 => 'BREAKDOWN',
      2 => 'MEDICAL',
      3 => 'STOPPED',
      4 => 'CUSTOM',
      _ => 'CRASH',
    };

    final fuelVal = bd.getUint16(offset, Endian.big);
    offset += 2;
    final fuelUsableKm = fuelVal == 0xFFFF ? null : fuelVal.toDouble();

    // Strings
    if (offset >= bytes.length - 2) return null;
    final userLen = bytes[offset++];
    if (offset + userLen > bytes.length - 2) return null;
    final userId = utf8.decode(bytes.sublist(offset, offset + userLen), allowMalformed: true);
    offset += userLen;

    if (offset >= bytes.length - 2) return null;
    final nameLen = bytes[offset++];
    if (offset + nameLen > bytes.length - 2) return null;
    final userName = utf8.decode(bytes.sublist(offset, offset + nameLen), allowMalformed: true);

    return MeshTelemetryPacket(
      version: version,
      joinCodeHash: joinCodeHash,
      userId: userId,
      userName: userName,
      lat: lat,
      lng: lng,
      speedKmh: speedKmh,
      heading: heading,
      batteryLevel: batteryLevel,
      isCharging: isCharging,
      role: role,
      isSos: isSos,
      sosType: sosType,
      seq: seq,
      ttl: ttl,
      hopCount: hopCount,
      timestampMs: timestampMs,
      fuelUsableKm: fuelUsableKm,
    );
  }

  /// Computes a standard CCITT CRC-16 (poly 0x1021) for error detection over wireless frames.
  static int computeCrc16(Uint8List data, int start, int end) {
    var crc = 0xFFFF;
    for (var i = start; i < end; i++) {
      crc ^= (data[i] << 8);
      for (var j = 0; j < 8; j++) {
        if ((crc & 0x8000) != 0) {
          crc = ((crc << 1) ^ 0x1021) & 0xFFFF;
        } else {
          crc = (crc << 1) & 0xFFFF;
        }
      }
    }
    return crc & 0xFFFF;
  }
}
