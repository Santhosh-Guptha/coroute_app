import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import '../../domain/tracking/geo_math.dart';

/// Verified offline emergency facility (hospital, trauma center, police, army transit post).
class EmergencyPlace {
  final String id;
  final String name;
  final String category; // 'HOSPITAL', 'TRAUMA_CENTER', 'POLICE', 'ARMY_CAMP'
  final double lat;
  final double lng;
  final String phone;
  final double routeKm;
  final bool isTraumaCenter;

  const EmergencyPlace({
    required this.id,
    required this.name,
    required this.category,
    required this.lat,
    required this.lng,
    this.phone = '',
    this.routeKm = 0.0,
    this.isTraumaCenter = false,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'category': category,
        'lat': lat,
        'lng': lng,
        'phone': phone,
        'route_km': routeKm,
        'is_trauma_center': isTraumaCenter ? 1 : 0,
      };

  factory EmergencyPlace.fromMap(Map<String, dynamic> map) => EmergencyPlace(
        id: map['id'] as String,
        name: map['name'] as String,
        category: map['category'] as String,
        lat: (map['lat'] as num).toDouble(),
        lng: (map['lng'] as num).toDouble(),
        phone: (map['phone'] as String?) ?? '',
        routeKm: (map['route_km'] as num?)?.toDouble() ?? 0.0,
        isTraumaCenter: (map['is_trauma_center'] as int?) == 1,
      );
}

/// An emergency place along with calculated distance and bearing from the rider.
class NearbyEmergencyPlace {
  final EmergencyPlace place;
  final double distanceMeters;
  final double bearingDegrees;

  const NearbyEmergencyPlace({
    required this.place,
    required this.distanceMeters,
    required this.bearingDegrees,
  });

  String get distanceKmFormatted => (distanceMeters / 1000).toStringAsFixed(1);

  String get bearingCardinal {
    const cardinals = ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'];
    final idx = ((bearingDegrees + 22.5) % 360 / 45).floor();
    return cardinals[idx.clamp(0, cardinals.length - 1)];
  }

  String get directionFormatted =>
      '$distanceKmFormatted km - $bearingCardinal ${bearingDegrees.round()} deg';
}

/// 100% offline SQLite spatial store for corridor trauma centers, hospitals,
/// and emergency services along active and pre-cached routes (REQ-02).
class EmergencyCorridorStore {
  EmergencyCorridorStore({Database? db}) {
    _db = db;
  }

  Database? _db;
  Future<Database>? _opening;

  /// Default seed places along high-risk remote Indian touring corridors
  /// (e.g. Manali-Leh, Spiti, Zojila, Western Ghats) so first responders have
  /// offline hospital references even before any trip pack is downloaded.
  static const List<EmergencyPlace> defaultSeedPlaces = [
    EmergencyPlace(
      id: 'hosp_keylong_dh',
      name: 'District Hospital Keylong (Lahaul)',
      category: 'HOSPITAL',
      lat: 32.5714,
      lng: 77.0321,
      phone: '+91 1900 222225',
      routeKm: 115.0,
      isTraumaCenter: true,
    ),
    EmergencyPlace(
      id: 'hosp_manali_ch',
      name: 'Civil Hospital Manali',
      category: 'HOSPITAL',
      lat: 32.2396,
      lng: 77.1887,
      phone: '+91 1902 252336',
      routeKm: 0.0,
      isTraumaCenter: true,
    ),
    EmergencyPlace(
      id: 'hosp_kaza_chc',
      name: 'Community Health Centre Kaza (Spiti)',
      category: 'HOSPITAL',
      lat: 32.2276,
      lng: 78.0710,
      phone: '+91 1906 222218',
      routeKm: 200.0,
      isTraumaCenter: false,
    ),
    EmergencyPlace(
      id: 'hosp_leh_snm',
      name: 'SNM Hospital Leh',
      category: 'HOSPITAL',
      lat: 34.1526,
      lng: 77.5771,
      phone: '+91 1982 252014',
      routeKm: 472.0,
      isTraumaCenter: true,
    ),
    EmergencyPlace(
      id: 'hosp_kargil_dh',
      name: 'District Hospital Kargil',
      category: 'HOSPITAL',
      lat: 34.5539,
      lng: 76.1349,
      phone: '+91 1985 232222',
      routeKm: 340.0,
      isTraumaCenter: true,
    ),
    EmergencyPlace(
      id: 'hosp_srinagar_smhs',
      name: 'SMHS Hospital Srinagar',
      category: 'HOSPITAL',
      lat: 34.0837,
      lng: 74.7973,
      phone: '+91 194 2504114',
      routeKm: 0.0,
      isTraumaCenter: true,
    ),
    EmergencyPlace(
      id: 'hosp_dharampur_chc',
      name: 'CHC Dharampur (NH5 Corridor)',
      category: 'HOSPITAL',
      lat: 30.9042,
      lng: 77.0271,
      phone: '+91 1792 264024',
      routeKm: 45.0,
      isTraumaCenter: false,
    ),
    EmergencyPlace(
      id: 'police_sissu_post',
      name: 'Police Post Sissu (North Portal Atal)',
      category: 'POLICE',
      lat: 32.4764,
      lng: 77.1234,
      phone: '112',
      routeKm: 40.0,
      isTraumaCenter: false,
    ),
  ];

  Future<Database> _open() {
    if (_db != null) return Future.value(_db!);
    return _opening ??= () async {
      final dir = await getDatabasesPath();
      final db = await openDatabase(
        p.join(dir, 'emergency_corridor.db'),
        version: 1,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE offline_emergency_places (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              category TEXT NOT NULL,
              lat REAL NOT NULL,
              lng REAL NOT NULL,
              phone TEXT,
              route_km REAL,
              is_trauma_center INTEGER NOT NULL DEFAULT 0
            )
          ''');
          await db.execute('CREATE INDEX idx_places_cat ON offline_emergency_places (category)');
          await db.execute('CREATE INDEX idx_places_trauma ON offline_emergency_places (is_trauma_center)');

          // Pre-seed default highway and mountain corridor facilities
          final batch = db.batch();
          for (final place in defaultSeedPlaces) {
            batch.insert(
              'offline_emergency_places',
              place.toMap(),
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
          await batch.commit(noResult: true);
        },
      );
      _db = db;
      return db;
    }();
  }

  /// Bulk upserts emergency places into the offline database.
  Future<void> upsertPlaces(List<EmergencyPlace> places) async {
    if (places.isEmpty) return;
    try {
      final db = await _open();
      final batch = db.batch();
      for (final p in places) {
        batch.insert(
          'offline_emergency_places',
          p.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    } catch (e) {
      debugPrint('EmergencyCorridorStore upsert error: $e');
    }
  }

  /// Returns closest emergency places ordered by great-circle distance.
  Future<List<NearbyEmergencyPlace>> getClosestPlaces(
    double lat,
    double lng, {
    int limit = 5,
    String? category,
    bool? traumaOnly,
  }) async {
    if (!lat.isFinite || !lng.isFinite) return const [];
    try {
      final db = await _open();
      String where = '';
      final whereArgs = <dynamic>[];

      if (category != null) {
        where = 'category = ?';
        whereArgs.add(category);
      }
      if (traumaOnly == true) {
        where = where.isEmpty ? 'is_trauma_center = 1' : '$where AND is_trauma_center = 1';
      }

      final rows = await db.query(
        'offline_emergency_places',
        where: where.isEmpty ? null : where,
        whereArgs: whereArgs.isEmpty ? null : whereArgs,
      );

      final withDistances = <NearbyEmergencyPlace>[];
      for (final row in rows) {
        final place = EmergencyPlace.fromMap(row);
        final dist = GeoMath.haversine(lat, lng, place.lat, place.lng);
        final bearing = _bearingBetween(lat, lng, place.lat, place.lng);
        withDistances.add(
          NearbyEmergencyPlace(
            place: place,
            distanceMeters: dist,
            bearingDegrees: bearing,
          ),
        );
      }

      withDistances.sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
      return withDistances.take(limit).toList();
    } catch (e) {
      debugPrint('EmergencyCorridorStore getClosestPlaces error: $e');
      return const [];
    }
  }

  /// Returns the 2 closest hospitals or trauma centers to the given coordinates.
  Future<List<NearbyEmergencyPlace>> getClosestHospitals(
    double lat,
    double lng, {
    int limit = 2,
  }) async {
    return getClosestPlaces(lat, lng, limit: limit, category: 'HOSPITAL');
  }

  /// Returns count of stored emergency places.
  Future<int> count() async {
    try {
      final db = await _open();
      final res = await db.rawQuery('SELECT COUNT(*) as c FROM offline_emergency_places');
      return Sqflite.firstIntValue(res) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Clears stored emergency places.
  Future<void> clear() async {
    try {
      final db = await _open();
      await db.delete('offline_emergency_places');
    } catch (_) {}
  }

  static double _bearingBetween(double lat1, double lng1, double lat2, double lng2) {
    final phi1 = lat1 * math.pi / 180.0;
    final phi2 = lat2 * math.pi / 180.0;
    final deltaLambda = (lng2 - lng1) * math.pi / 180.0;
    final y = math.sin(deltaLambda) * math.cos(phi2);
    final x = math.cos(phi1) * math.sin(phi2) - math.sin(phi1) * math.cos(phi2) * math.cos(deltaLambda);
    final bearingRad = math.atan2(y, x);
    return ((bearingRad * 180.0 / math.pi) + 360.0) % 360.0;
  }
}
