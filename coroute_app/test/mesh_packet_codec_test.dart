import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/mesh/mesh_telemetry_packet.dart';
import 'package:coroute_app/domain/mesh/mesh_packet_codec.dart';

void main() {
  group('MeshPacketCodec Tests', () {
    test('Round-trip encode and decode preserves full telemetry', () {
      const original = MeshTelemetryPacket(
        joinCodeHash: 0x4B21,
        userId: 'rider_99',
        userName: 'Vikram',
        lat: 12.971598,
        lng: 77.594562,
        speedKmh: 82.5,
        heading: 145.0,
        batteryLevel: 78,
        isCharging: true,
        role: 'LEAD',
        isSos: false,
        sosType: 'CRASH',
        seq: 1042,
        ttl: 3,
        hopCount: 0,
        timestampMs: 1728938400000,
        fuelUsableKm: 185.0,
      );

      final encoded = MeshPacketCodec.encode(original);
      expect(encoded.length, greaterThanOrEqualTo(MeshPacketCodec.minPacketSize));

      final decoded = MeshPacketCodec.decode(encoded);
      expect(decoded, isNotNull);
      expect(decoded!.joinCodeHash, equals(0x4B21));
      expect(decoded.userId, equals('rider_99'));
      expect(decoded.userName, equals('Vikram'));
      expect(decoded.lat, closeTo(12.971598, 0.00001));
      expect(decoded.lng, closeTo(77.594562, 0.00001));
      expect(decoded.speedKmh, equals(83.0)); // rounded km/h byte
      expect(decoded.heading, closeTo(145.0, 2.0));
      expect(decoded.batteryLevel, equals(78));
      expect(decoded.isCharging, isTrue);
      expect(decoded.role, equals('LEAD'));
      expect(decoded.isSos, isFalse);
      expect(decoded.seq, equals(1042));
      expect(decoded.ttl, equals(3));
      expect(decoded.hopCount, equals(0));
      expect(decoded.timestampMs, equals(1728938400000));
      expect(decoded.fuelUsableKm, equals(185.0));
    });

    test('SOS distress beacon encoding and decoding', () {
      const sosPacket = MeshTelemetryPacket(
        joinCodeHash: 0x9A12,
        userId: 'rider_42',
        userName: 'Rahul',
        lat: 13.0827,
        lng: 80.2707,
        speedKmh: 0.0,
        heading: 0.0,
        batteryLevel: 45,
        isCharging: false,
        role: 'SWEEPER',
        isSos: true,
        sosType: 'BREAKDOWN',
        seq: 55,
        ttl: 2,
        hopCount: 1,
        timestampMs: 1728940000000,
      );

      final encoded = MeshPacketCodec.encode(sosPacket);
      final decoded = MeshPacketCodec.decode(encoded);

      expect(decoded, isNotNull);
      expect(decoded!.isSos, isTrue);
      expect(decoded.sosType, equals('BREAKDOWN'));
      expect(decoded.role, equals('SWEEPER'));
      expect(decoded.ttl, equals(2));
      expect(decoded.hopCount, equals(1));
      expect(decoded.fuelUsableKm, isNull);
    });

    test('Tampered CRC-16 checksum causes decode to reject corrupted frame', () {
      const packet = MeshTelemetryPacket(
        joinCodeHash: 0x1234,
        userId: 'user_1',
        userName: 'Priya',
        lat: 15.0,
        lng: 75.0,
        speedKmh: 50.0,
        heading: 90.0,
        seq: 1,
        timestampMs: 1000,
      );

      final encoded = MeshPacketCodec.encode(packet);
      expect(MeshPacketCodec.decode(encoded), isNotNull);

      // Corrupt a byte in the payload
      final corrupted = Uint8List.fromList(encoded);
      corrupted[10] ^= 0xFF;

      expect(MeshPacketCodec.decode(corrupted), isNull);
    });

    test('Truncated data returns null', () {
      final truncated = Uint8List.fromList([0x43, 0x52, 0x01, 0x00]);
      expect(MeshPacketCodec.decode(truncated), isNull);
    });

    test('Join code hash produces consistent 16-bit integer', () {
      final hash1 = MeshTelemetryPacket.hashJoinCode('HAWK7');
      final hash2 = MeshTelemetryPacket.hashJoinCode('hawk7 ');
      expect(hash1, equals(hash2));
      expect(hash1, inInclusiveRange(0, 0xFFFF));

      final hashDiff = MeshTelemetryPacket.hashJoinCode('FALCON8');
      expect(hash1, isNot(equals(hashDiff)));
    });

    test('copyForRelay decrements TTL and increments hop count', () {
      const original = MeshTelemetryPacket(
        joinCodeHash: 0x1111,
        userId: 'rider_1',
        userName: 'Alex',
        lat: 10.0,
        lng: 20.0,
        speedKmh: 60.0,
        heading: 180.0,
        seq: 10,
        ttl: 3,
        hopCount: 0,
        timestampMs: 5000,
      );

      expect(original.isDirectPeer, isTrue);
      expect(original.isRelayed, isFalse);

      final relayed = original.copyForRelay();
      expect(relayed.ttl, equals(2));
      expect(relayed.hopCount, equals(1));
      expect(relayed.isDirectPeer, isFalse);
      expect(relayed.isRelayed, isTrue);
      expect(relayed.userId, equals('rider_1'));
      expect(relayed.seq, equals(10));
    });
  });
}
