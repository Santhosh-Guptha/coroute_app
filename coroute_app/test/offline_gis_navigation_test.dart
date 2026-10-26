import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coroute_app/core/config/feature_gates.dart';
import 'package:coroute_app/core/theme/app_theme.dart';
import 'package:coroute_app/data/models/rider_model.dart';
import 'package:coroute_app/data/services/tile_cache_service.dart';
import 'package:coroute_app/presentation/rider/widgets/cockpit_dual_state_banner.dart';
import 'package:coroute_app/presentation/rider/widgets/ghost_rider_marker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CockpitDualStateBanner Tests', () {
    testWidgets('renders [ 🗺️ OFFLINE · PACK ACTIVE | 📶 X P2P Peers ] with neon teal outline when cached', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: const Scaffold(
            body: CockpitDualStateBanner(
              isPackActive: true,
              peerCount: 4,
              isOffline: true,
            ),
          ),
        ),
      );

      // Verify text and emoji components
      expect(find.text('🗺️'), findsOneWidget);
      expect(find.text('OFFLINE · PACK ACTIVE'), findsOneWidget);
      expect(find.text('|'), findsOneWidget);
      expect(find.text('📶'), findsOneWidget);
      expect(find.text('4 P2P Peers'), findsOneWidget);

      // Verify container decoration and neon cyan border
      final containerFinder = find.byType(Container).first;
      final container = tester.widget<Container>(containerFinder);
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.border, isNotNull);
      final border = decoration.border as Border;
      expect(border.top.color, AppTheme.neonCyan);
      expect(border.top.width, 2.0);
    });

    testWidgets('renders [ ⚠️ OFFLINE · TERRAIN UNCACHED ] with amber warning outline when uncached', (tester) async {
      bool prefetchTriggered = false;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: Scaffold(
            body: CockpitDualStateBanner(
              isPackActive: false,
              peerCount: 0,
              isOffline: true,
              onPrefetch: () {
                prefetchTriggered = true;
              },
            ),
          ),
        ),
      );

      // Verify warning text and emoji components
      expect(find.text('⚠️'), findsOneWidget);
      expect(find.text('OFFLINE · TERRAIN UNCACHED'), findsOneWidget);
      expect(find.text('CACHE'), findsOneWidget);

      // Verify hyper amber border
      final containerFinder = find.byType(Container).first;
      final container = tester.widget<Container>(containerFinder);
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.border, isNotNull);
      final border = decoration.border as Border;
      expect(border.top.color, AppTheme.hyperAmber);
      expect(border.top.width, 2.0);

      // Verify tap on CACHE action triggers prefetch
      await tester.tap(find.text('CACHE'));
      await tester.pumpAndSettle();
      expect(prefetchTriggered, isTrue);
    });

    testWidgets('renders shrink SizedBox when not offline', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: const Scaffold(
            body: CockpitDualStateBanner(
              isPackActive: true,
              peerCount: 2,
              isOffline: false,
            ),
          ),
        ),
      );

      expect(find.text('OFFLINE · PACK ACTIVE'), findsNothing);
      expect(find.byType(SizedBox), findsOneWidget);
    });
  });

  group('GhostRiderMarker Tests', () {
    final now = 1700000000000;

    test('isDropped correctly identifies dropped riders > 30s stale', () {
      final freshRider = RiderModel(
        userId: 'r1',
        name: 'Arjun Mehta',
        vehicleType: 'KTM 390',
        vehicleColor: 'Orange',
        lat: 12.9716,
        lng: 77.5946,
        speedKmh: 45,
        heading: 90,
        batteryLevel: 80,
        isCharging: false,
        role: 'PACK',
        statusReason: '',
        statusMessage: '',
        lastSeenEpochMs: now - 20000, // 20s ago (fresh)
      );

      final staleRider = RiderModel(
        userId: 'r2',
        name: 'Kiran Rao',
        vehicleType: 'Himalayan 450',
        vehicleColor: 'White',
        lat: 12.9720,
        lng: 77.5950,
        speedKmh: 0,
        heading: 0,
        batteryLevel: 40,
        isCharging: false,
        role: 'PACK',
        statusReason: '',
        statusMessage: '',
        lastSeenEpochMs: now - 180000, // 3m ago (dropped)
      );

      final noFixRider = RiderModel(
        userId: 'r3',
        name: 'Vikram',
        vehicleType: 'BMW GS',
        vehicleColor: 'Black',
        lat: 0,
        lng: 0,
        speedKmh: 0,
        heading: 0,
        batteryLevel: 90,
        isCharging: false,
        role: 'PACK',
        statusReason: '',
        statusMessage: '',
        lastSeenEpochMs: 0, // Never heard from
      );

      expect(GhostRiderMarker.isDropped(freshRider, now), isFalse);
      expect(GhostRiderMarker.isDropped(staleRider, now), isTrue);
      expect(GhostRiderMarker.isDropped(noFixRider, now), isTrue);
    });

    test('formatElapsedBadge produces accurate human-readable time strings', () {
      expect(GhostRiderMarker.formatElapsedBadge('Kiran Rao', now - 180000, now), 'Kiran · 3m ago');
      expect(GhostRiderMarker.formatElapsedBadge('Kiran Rao', now - 45000, now), 'Kiran · 45s ago');
      expect(GhostRiderMarker.formatElapsedBadge('Kiran Rao', now - 7200000, now), 'Kiran · 2h ago');
      expect(GhostRiderMarker.formatElapsedBadge('Kiran Rao', 0, now), 'Kiran · Dropped');
    });

    testWidgets('renders desaturated avatar, 60% opacity, dashed radar halo, and elapsed badge', (tester) async {
      bool tapped = false;
      final droppedRider = RiderModel(
        userId: 'r2',
        name: 'Kiran Rao',
        vehicleType: 'Himalayan 450',
        vehicleColor: 'White',
        lat: 12.9720,
        lng: 77.5950,
        speedKmh: 0,
        heading: 0,
        batteryLevel: 40,
        isCharging: false,
        role: 'PACK',
        statusReason: '',
        statusMessage: '',
        lastSeenEpochMs: now - 180000, // 3m ago
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          home: Scaffold(
            body: Center(
              child: GhostRiderMarker(
                rider: droppedRider,
                nowMs: now,
                onTap: () {
                  tapped = true;
                },
              ),
            ),
          ),
        ),
      );

      // Verify 60% opacity
      final opacityFinder = find.byType(Opacity);
      expect(opacityFinder, findsOneWidget);
      final opacity = tester.widget<Opacity>(opacityFinder);
      expect(opacity.opacity, 0.60);

      // Verify desaturation ColorFiltered
      final colorFilteredFinder = find.byType(ColorFiltered);
      expect(colorFilteredFinder, findsOneWidget);

      // Verify time-elapsed badge pill
      expect(find.text('Kiran · 3m ago'), findsOneWidget);
      expect(find.text('LAST SEEN FIX'), findsOneWidget);

      // Verify radar halo CustomPaint
      expect(find.byType(CustomPaint), findsWidgets);

      // Verify tap interaction
      await tester.tap(find.byType(GhostRiderMarker));
      await tester.pumpAndSettle();
      expect(tapped, isTrue);
    });
  });

  group('2.5km Corridor Caching and Intermediate Zoom Levels', () {
    test('covers intermediate zoom levels (11, 12, 13, 14, 15, 16)', () {
      final routeLine = [
        (17.3850, 78.4867),
        (17.3940, 78.4867),
        (17.4030, 78.4867),
      ];

      final standardTiles = TilePrefetcher.tilesAlong(routeLine, highDetail: false);

      final zoomsPresent = standardTiles.map((t) => t.$1).toSet();
      // All intermediate zooms (11, 12, 13, 14, 15, 16) must be present
      for (final z in [11, 12, 13, 14, 15, 16]) {
        expect(zoomsPresent.contains(z), isTrue, reason: 'Zoom level $z must be covered for smooth zoom');
      }
    });

    test('2.5 km lateral corridor buffering includes lateral tile neighbours', () {
      final singlePoint = [(17.3850, 78.4867), (17.3855, 78.4867)];
      final tiles = TilePrefetcher.tilesAlong(singlePoint, zooms: const [14]);

      // At zoom 14, 2.5 km lateral corridor spans across a 3x3 block (>= 9 tiles)
      expect(tiles.length, greaterThanOrEqualTo(9));
      final center = TilePrefetcher.tileOf(17.3850, 78.4867, 14);
      expect(tiles.contains((14, center.$1, center.$2)), isTrue);
      // Diagonals within 2.5 km lateral corridor
      expect(tiles.contains((14, center.$1 + 1, center.$2 + 1)), isTrue);
      expect(tiles.contains((14, center.$1 - 1, center.$2 - 1)), isTrue);
    });

    test('FeatureGates.isUnlocked(Feature.unlimitedOfflinePacks) hook connects correctly', () {
      final prevForce = FeatureGates.forceAllUnlocked;
      FeatureGates.forceAllUnlocked = true;
      try {
        expect(TilePrefetcher.hasUnlimitedOfflinePacks, isTrue);
        expect(FeatureGates.isUnlocked(Feature.unlimitedOfflinePacks), isTrue);
      } finally {
        FeatureGates.forceAllUnlocked = prevForce;
      }
    });
  });
}
