import 'dart:typed_data';
import '../../data/services/biometric_safety_bridge.dart';

/// Severity/trauma classification in Byte 14 of the compact SOS packet.
enum SosSeverity {
  manual(0, 'Manual SOS', 'MANUAL_SOS'),
  crashAuto(1, 'Crash Detected (Unverified)', 'CRASH_AUTO'),
  stableTrauma(2, 'Stable Vitals', 'STABLE_TRAUMA'),
  elevatedTrauma(3, 'Elevated Stress', 'ELEVATED_TRAUMA'),
  criticalTraumaL1(4, 'Critical Trauma Level 1', 'CRITICAL_TRAUMA_L1'),
  wearableAlarm(5, 'Wearable Alarm', 'WEARABLE_ALARM'),
  needHelp(6, 'Assistance Needed', 'NEED_HELP');

  final int code;
  final String label;
  final String wire;

  const SosSeverity(this.code, this.label, this.wire);

  static SosSeverity fromCode(int code) {
    for (final val in SosSeverity.values) {
      if (val.code == code) return val;
    }
    return SosSeverity.manual;
  }

  static SosSeverity fromTraumaLevel(BiometricTraumaLevel level, {bool isCrash = true}) {
    if (!isCrash) return SosSeverity.manual;
    switch (level) {
      case BiometricTraumaLevel.stableTrauma:
        return SosSeverity.stableTrauma;
      case BiometricTraumaLevel.elevatedTrauma:
        return SosSeverity.elevatedTrauma;
      case BiometricTraumaLevel.criticalTraumaLevel1:
        return SosSeverity.criticalTraumaL1;
      case BiometricTraumaLevel.unverified:
        return SosSeverity.crashAuto;
    }
  }
}

/// Decoded content of an internal 16-byte SOS packet.
class DecodedSosPacket {
  final double latitude;
  final double longitude;
  final double? altitudeMeters;
  final DateTime timestamp;
  final SosSeverity severity;
  final String? bloodGroup;
  final int checksum;

  const DecodedSosPacket({
    required this.latitude,
    required this.longitude,
    required this.altitudeMeters,
    required this.timestamp,
    required this.severity,
    required this.bloodGroup,
    required this.checksum,
  });

  @override
  String toString() =>
      'DecodedSosPacket(lat: ${latitude.toStringAsFixed(6)}, lng: ${longitude.toStringAsFixed(6)}, '
      'alt: $altitudeMeters, time: ${timestamp.toIso8601String()}, '
      'severity: ${severity.wire}, blood: $bloodGroup, csum: $checksum)';
}

/// High-density 16-byte binary codec for satellite, NTN, and low-bandwidth emergency relays.
class SosPacketCodec {
  static const int packetLength = 16;
  static const int sentinelAltitude = 0x7FFF; // 32767 meters

  static const List<String> _bloodGroups = [
    '', // 0: Unknown / Unconsented
    'A+', // 1
    'A-', // 2
    'B+', // 3
    'B-', // 4
    'AB+', // 5
    'AB-', // 6
    'O+', // 7
    'O-', // 8
  ];

  /// Encode blood group string to 4-bit nibble (0-8).
  static int encodeBloodGroup(String? bloodGroup) {
    if (bloodGroup == null || bloodGroup.isEmpty) return 0;
    final normalized = bloodGroup.trim().toUpperCase();
    final idx = _bloodGroups.indexOf(normalized);
    return idx > 0 ? idx : 0;
  }

  /// Decode 4-bit nibble (0-8) to blood group string or null.
  static String? decodeBloodGroup(int code) {
    if (code >= 1 && code < _bloodGroups.length) {
      return _bloodGroups[code];
    }
    return null;
  }

  /// Calculates the modulo-16 checksum nibble so that the sum of all 32 nibbles
  /// across the 16 bytes equals 0 modulo 16.
  static int calculateChecksum(Uint8List bytes15, int bloodGroupNibble) {
    int sum = 0;
    for (int i = 0; i < 15; i++) {
      final b = bytes15[i];
      sum += (b >> 4) & 0x0F;
      sum += b & 0x0F;
    }
    sum += bloodGroupNibble & 0x0F;
    return (16 - (sum % 16)) % 16;
  }

  /// Verifies whether the entire 16-byte packet satisfies the modulo-16 checksum.
  static bool verifyChecksum(Uint8List bytes) {
    if (bytes.length != packetLength) return false;
    int sum = 0;
    for (int i = 0; i < packetLength; i++) {
      final b = bytes[i];
      sum += (b >> 4) & 0x0F;
      sum += b & 0x0F;
    }
    return (sum % 16) == 0;
  }

  /// Encodes SOS telemetry into a 16-byte binary buffer.
  static Uint8List encode({
    required double latitude,
    required double longitude,
    double? altitudeMeters,
    required DateTime timestamp,
    SosSeverity severity = SosSeverity.manual,
    String? bloodGroup,
  }) {
    if (latitude.isNaN || latitude.isInfinite || latitude < -90.0 || latitude > 90.0) {
      throw ArgumentError.value(latitude, 'latitude', 'Must be between -90.0 and +90.0 degrees');
    }
    if (longitude.isNaN || longitude.isInfinite || longitude < -180.0 || longitude > 180.0) {
      throw ArgumentError.value(longitude, 'longitude', 'Must be between -180.0 and +180.0 degrees');
    }

    final epochSeconds = timestamp.toUtc().millisecondsSinceEpoch ~/ 1000;
    if (epochSeconds < 0 || epochSeconds > 0xFFFFFFFF) {
      throw ArgumentError.value(timestamp, 'timestamp', 'Epoch seconds must fit in 32-bit unsigned integer');
    }

    final bytes = Uint8List(packetLength);
    final buffer = ByteData.sublistView(bytes);

    // Bytes 0-3: Latitude (10^7 scaling, 32-bit signed int, Big Endian)
    final latFixed = (latitude * 1e7).round();
    buffer.setInt32(0, latFixed, Endian.big);

    // Bytes 4-7: Longitude (10^7 scaling, 32-bit signed int, Big Endian)
    final lngFixed = (longitude * 1e7).round();
    buffer.setInt32(4, lngFixed, Endian.big);

    // Bytes 8-9: Altitude in meters (16-bit signed int, Big Endian, 0x7FFF = unknown)
    int altInt;
    if (altitudeMeters == null || altitudeMeters.isNaN || altitudeMeters.isInfinite) {
      altInt = sentinelAltitude;
    } else {
      final rounded = altitudeMeters.round();
      if (rounded < -32768 || rounded > 32766) {
        altInt = sentinelAltitude;
      } else {
        altInt = rounded;
      }
    }
    buffer.setInt16(8, altInt, Endian.big);

    // Bytes 10-13: UTC timestamp in epoch seconds (32-bit unsigned int, Big Endian)
    buffer.setUint32(10, epochSeconds, Endian.big);

    // Byte 14: Severity code (8-bit unsigned int)
    buffer.setUint8(14, severity.code & 0xFF);

    // Byte 15: Upper 4 bits = Blood Group; Lower 4 bits = Modulo-16 Checksum
    final bgNibble = encodeBloodGroup(bloodGroup) & 0x0F;
    final checksum = calculateChecksum(bytes, bgNibble);
    final byte15 = (bgNibble << 4) | (checksum & 0x0F);
    buffer.setUint8(15, byte15);

    return bytes;
  }

  /// Decodes a 16-byte buffer back into a validated [DecodedSosPacket].
  static DecodedSosPacket decode(Uint8List bytes) {
    if (bytes.length != packetLength) {
      throw ArgumentError('SOS packet must be exactly $packetLength bytes, got ${bytes.length}');
    }

    if (!verifyChecksum(bytes)) {
      throw const FormatException('SOS packet checksum verification failed');
    }

    final buffer = ByteData.sublistView(bytes);

    final latFixed = buffer.getInt32(0, Endian.big);
    final latitude = latFixed / 1e7;

    final lngFixed = buffer.getInt32(4, Endian.big);
    final longitude = lngFixed / 1e7;

    final altRaw = buffer.getInt16(8, Endian.big);
    final altitudeMeters = altRaw == sentinelAltitude ? null : altRaw.toDouble();

    final epochSeconds = buffer.getUint32(10, Endian.big);
    final timestamp = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000, isUtc: true);

    final severityCode = buffer.getUint8(14);
    final severity = SosSeverity.fromCode(severityCode);

    final byte15 = buffer.getUint8(15);
    final bgNibble = (byte15 >> 4) & 0x0F;
    final checksum = byte15 & 0x0F;

    return DecodedSosPacket(
      latitude: latitude,
      longitude: longitude,
      altitudeMeters: altitudeMeters,
      timestamp: timestamp,
      severity: severity,
      bloodGroup: decodeBloodGroup(bgNibble),
      checksum: checksum,
    );
  }

  /// Hex string utility
  static String toHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List fromHex(String hex) {
    final clean = hex.replaceAll(RegExp(r'\s+'), '');
    if (clean.length % 2 != 0) {
      throw ArgumentError('Hex string must have an even length');
    }
    final bytes = Uint8List(clean.length ~/ 2);
    for (int i = 0; i < clean.length; i += 2) {
      bytes[i ~/ 2] = int.parse(clean.substring(i, i + 2), radix: 16);
    }
    return bytes;
  }
}
