/// Comprehensive parser for geographic coordinates from text, clipboards,
/// and map sharing URLs.
///
/// Supports:
/// - Decimal degrees: `17.385044, 78.486712` or `17.385044 78.486712` or `-33.8688, 151.2093`
/// - With cardinal letters: `17.385044N, 78.486712E` or `33.8688 S, 151.2093 E`
/// - Degrees Minutes Seconds (DMS): `17°23'06.2"N 78°29'12.2"E`
/// - Google Maps URLs: `https://maps.google.com/?q=17.3850,78.4867` or `.../maps/@17.3850,78.4867,15z`
/// - Geo URIs: `geo:17.3850,78.4867`
class CoordinateParser {
  CoordinateParser._();

  /// Decimal degrees regex: e.g. 17.385044, 78.486712 or 17.385044 -78.486712
  static final RegExp _decimalPattern = RegExp(
    r'^[^\d+-]*([+-]?\d{1,2}(?:\.\d+)?)\s*(?:°)?\s*([NSEWnsew])?[\s,;]+([+-]?\d{1,3}(?:\.\d+)?)\s*(?:°)?\s*([NSEWnsew])?[^\d]*$',
  );

  /// DMS regex: e.g. 17°23'06.2"N 78°29'12.2"E
  static final RegExp _dmsPattern = RegExp(
    r'(\d{1,2})[°\s]+(\d{1,2})[\x27\x60\s]+(\d{1,2}(?:\.\d+)?)[\x22\s]*([NSEWnsew])[\s,;]+(\d{1,3})[°\s]+(\d{1,2})[\x27\x60\s]+(\d{1,2}(?:\.\d+)?)[\x22\s]*([NSEWnsew])',
  );

  /// Google Maps query or @lat,lng URL regex
  static final RegExp _urlPattern = RegExp(
    r'[?&](?:q|query|ll|sll|dll)=([+-]?\d{1,2}\.\d+),([+-]?\d{1,3}\.\d+)|@([+-]?\d{1,2}\.\d+),([+-]?\d{1,3}\.\d+)|geo:([+-]?\d{1,2}\.\d+),([+-]?\d{1,3}\.\d+)',
  );

  /// Parses [input] string into `(double lat, double lng)` if valid coordinates are found.
  /// Returns `null` if the input is not a recognized coordinate representation.
  static (double lat, double lng)? tryParse(String? input) {
    if (input == null) return null;
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    // 1. Try URL / Geo URI extraction first
    final urlMatch = _urlPattern.firstMatch(trimmed);
    if (urlMatch != null) {
      final latStr = urlMatch.group(1) ?? urlMatch.group(3) ?? urlMatch.group(5);
      final lngStr = urlMatch.group(2) ?? urlMatch.group(4) ?? urlMatch.group(6);
      if (latStr != null && lngStr != null) {
        final lat = double.tryParse(latStr);
        final lng = double.tryParse(lngStr);
        if (lat != null && lng != null && _isValid(lat, lng)) {
          return (lat, lng);
        }
      }
    }

    // 2. Try DMS (Degrees Minutes Seconds)
    final dmsMatch = _dmsPattern.firstMatch(trimmed);
    if (dmsMatch != null) {
      try {
        final d1 = double.parse(dmsMatch.group(1)!);
        final m1 = double.parse(dmsMatch.group(2)!);
        final s1 = double.parse(dmsMatch.group(3)!);
        final dir1 = dmsMatch.group(4)!.toUpperCase();

        final d2 = double.parse(dmsMatch.group(5)!);
        final m2 = double.parse(dmsMatch.group(6)!);
        final s2 = double.parse(dmsMatch.group(7)!);
        final dir2 = dmsMatch.group(8)!.toUpperCase();

        var val1 = d1 + (m1 / 60.0) + (s1 / 3600.0);
        if (dir1 == 'S' || dir1 == 'W') val1 = -val1;

        var val2 = d2 + (m2 / 60.0) + (s2 / 3600.0);
        if (dir2 == 'S' || dir2 == 'W') val2 = -val2;

        final isLatFirst = (dir1 == 'N' || dir1 == 'S');
        final lat = isLatFirst ? val1 : val2;
        final lng = isLatFirst ? val2 : val1;

        if (_isValid(lat, lng)) return (lat, lng);
      } catch (_) {}
    }

    // 3. Try standard decimal format
    final decMatch = _decimalPattern.firstMatch(trimmed);
    if (decMatch != null) {
      final num1 = double.tryParse(decMatch.group(1)!);
      final dir1 = decMatch.group(2)?.toUpperCase();
      final num2 = double.tryParse(decMatch.group(3)!);
      final dir2 = decMatch.group(4)?.toUpperCase();

      if (num1 != null && num2 != null) {
        var val1 = num1;
        if (dir1 == 'S' || dir1 == 'W') val1 = -val1.abs();
        if (dir1 == 'N' || dir1 == 'E') val1 = val1.abs();

        var val2 = num2;
        if (dir2 == 'S' || dir2 == 'W') val2 = -val2.abs();
        if (dir2 == 'N' || dir2 == 'E') val2 = val2.abs();

        final isLatFirst = (dir1 == null || dir1 == 'N' || dir1 == 'S');
        final lat = isLatFirst ? val1 : val2;
        final lng = isLatFirst ? val2 : val1;

        if (_isValid(lat, lng)) return (lat, lng);
      }
    }

    return null;
  }

  static bool _isValid(double lat, double lng) {
    return lat.isFinite &&
        lng.isFinite &&
        lat >= -90.0 &&
        lat <= 90.0 &&
        lng >= -180.0 &&
        lng <= 180.0 &&
        !(lat == 0.0 && lng == 0.0);
  }
}
