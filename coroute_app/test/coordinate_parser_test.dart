import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/domain/tracking/coordinate_parser.dart';

void main() {
  group('CoordinateParser Tests', () {
    test('parses standard comma-separated decimal degrees', () {
      final res = CoordinateParser.tryParse('17.385044, 78.486671');
      expect(res, isNotNull);
      expect(res!.$1, closeTo(17.385044, 0.00001));
      expect(res.$2, closeTo(78.486671, 0.00001));
    });

    test('parses space-separated decimal degrees', () {
      final res = CoordinateParser.tryParse('12.971598 77.594566');
      expect(res, isNotNull);
      expect(res!.$1, closeTo(12.971598, 0.00001));
      expect(res.$2, closeTo(77.594566, 0.00001));
    });

    test('parses negative coordinates (Western / Southern hemisphere)', () {
      final res = CoordinateParser.tryParse('-33.8688, 151.2093');
      expect(res, isNotNull);
      expect(res!.$1, closeTo(-33.8688, 0.0001));
      expect(res.$2, closeTo(151.2093, 0.0001));
    });

    test('parses decimal degrees with cardinal directions N/E', () {
      final res = CoordinateParser.tryParse('17.3850N, 78.4867E');
      expect(res, isNotNull);
      expect(res!.$1, closeTo(17.3850, 0.0001));
      expect(res.$2, closeTo(78.4867, 0.0001));
    });

    test('parses decimal degrees reversed with cardinal directions E/N', () {
      final res = CoordinateParser.tryParse('78.4867E, 17.3850N');
      expect(res, isNotNull);
      expect(res!.$1, closeTo(17.3850, 0.0001));
      expect(res.$2, closeTo(78.4867, 0.0001));
    });

    test('parses decimal degrees with cardinal directions S/W', () {
      final res = CoordinateParser.tryParse('33.8688 S, 70.6693 W');
      expect(res, isNotNull);
      expect(res!.$1, closeTo(-33.8688, 0.0001));
      expect(res.$2, closeTo(-70.6693, 0.0001));
    });

    test('parses DMS format', () {
      final res = CoordinateParser.tryParse('17°23\'06.2"N 78°29\'12.0"E');
      expect(res, isNotNull);
      // 17 + 23/60 + 6.2/3600 = 17.385055
      expect(res!.$1, closeTo(17.385055, 0.001));
      // 78 + 29/60 + 12.0/3600 = 78.486666
      expect(res.$2, closeTo(78.486666, 0.001));
    });

    test('parses Google Maps URL query format', () {
      final res = CoordinateParser.tryParse('https://www.google.com/maps?q=17.385044,78.486671');
      expect(res, isNotNull);
      expect(res!.$1, closeTo(17.385044, 0.00001));
      expect(res.$2, closeTo(78.486671, 0.00001));
    });

    test('parses Google Maps @lat,lng URL format', () {
      final res = CoordinateParser.tryParse('https://www.google.com/maps/@17.385044,78.486671,15z');
      expect(res, isNotNull);
      expect(res!.$1, closeTo(17.385044, 0.00001));
      expect(res.$2, closeTo(78.486671, 0.00001));
    });

    test('parses geo: URI format', () {
      final res = CoordinateParser.tryParse('geo:17.385044,78.486671');
      expect(res, isNotNull);
      expect(res!.$1, closeTo(17.385044, 0.00001));
      expect(res.$2, closeTo(78.486671, 0.00001));
    });

    test('returns null for text search phrases and invalid coordinates', () {
      expect(CoordinateParser.tryParse('Bangalore Palace'), isNull);
      expect(CoordinateParser.tryParse('NH 44 Highway Cafe'), isNull);
      expect(CoordinateParser.tryParse(''), isNull);
      expect(CoordinateParser.tryParse('   '), isNull);
      expect(CoordinateParser.tryParse('999.999, 999.999'), isNull); // out of range
      expect(CoordinateParser.tryParse('0.0, 0.0'), isNull); // null island
    });
  });
}
