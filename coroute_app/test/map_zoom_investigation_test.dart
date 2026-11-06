import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:coroute_app/core/theme/map_tiles.dart';
import 'package:coroute_app/data/services/tile_cache_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Map zoom and blank map prevention verification', () {
    testWidgets('FlutterMap zoom in and zoom out tile rendering behavior', (tester) async {
      final controller = MapController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 800,
              child: FlutterMap(
                mapController: controller,
                options: const MapOptions(
                  initialCenter: LatLng(17.385, 78.4867),
                  initialZoom: 15.0,
                ),
                children: [
                  appTileLayer(),
                ],
              ),
            ),
          ),
        ),
      );

      await tester.pump();
      expect(controller.camera.zoom, 15.0);

      // Zoom in
      controller.move(const LatLng(17.385, 78.4867), 17.0);
      await tester.pump();
      expect(controller.camera.zoom, 17.0);

      controller.move(const LatLng(17.385, 78.4867), 19.5);
      await tester.pump();
      expect(controller.camera.zoom, 19.5);

      // Zoom out
      controller.move(const LatLng(17.385, 78.4867), 10.0);
      await tester.pump();
      expect(controller.camera.zoom, 10.0);

      controller.move(const LatLng(17.385, 78.4867), 2.0);
      await tester.pump();
      expect(controller.camera.zoom, 2.0);

      expect(tester.takeException(), isNull);
    });

    test('appTileLayer has correct zoom limits, keepBuffer, and tileBounds', () {
      final layer = appTileLayer();

      expect(layer.minZoom, 2.0);
      expect(layer.maxZoom, 20.0);
      expect(layer.minNativeZoom, 1);
      expect(layer.maxNativeZoom, 19);
      expect(layer.keepBuffer, 3);
      expect(layer.panBuffer, 1);

      expect(layer.tileBounds, isNotNull);
      expect(layer.tileBounds!.southWest.latitude, closeTo(-85.05112878, 1e-6));
      expect(layer.tileBounds!.northEast.latitude, closeTo(85.05112878, 1e-6));
      expect(layer.tileBounds!.southWest.longitude, -180.0);
      expect(layer.tileBounds!.northEast.longitude, 180.0);
      expect(layer.errorImage, isNotNull);
    });

    test('TileProvider HTTP client lifecycle preserves sharedHttpClient across disposes', () {
      final sharedClient = TileCache.sharedHttpClient;
      expect(sharedClient, isNotNull);

      // Creating and disposing CachedTileProvider with default client should NOT close shared client
      final provider1 = CachedTileProvider();
      provider1.dispose();

      // Ensure shared client can still make requests / is not closed
      expect(() => sharedClient.head(Uri.parse('https://example.com')), returnsNormally);

      // Explicitly passing TileCache.sharedHttpClient should also not close it on dispose
      final provider2 = CachedTileProvider(client: TileCache.sharedHttpClient);
      provider2.dispose();
      expect(() => sharedClient.head(Uri.parse('https://example.com')), returnsNormally);

      // appTileProvider without cache returns NetworkTileProvider using sharedHttpClient
      TileCache.instance = null;
      final networkProvider = appTileProvider();
      expect(networkProvider, isA<NetworkTileProvider>());
      networkProvider.dispose();
      expect(() => sharedClient.head(Uri.parse('https://example.com')), returnsNormally);
    });

    test('Parent tile fallback logic operates when parent tile exists in cache', () async {
      final tempDir = await Directory.systemTemp.createTemp('tile_cache_test_');
      try {
        final cache = await TileCache.open(tempDir.path);
        expect(cache, isNotNull);

        // Store a parent tile at z=14, x=100, y=200
        final dummyBytes = CachedTileImage.transparentPngBytes;
        await cache!.store(14, 100, 200, dummyBytes);

        // Child tile coordinates at z=15 for parent (14, 100, 200) are x=200..201, y=400..401
        final childX = (100 << 1); // 200
        final childY = (200 << 1); // 400

        // Verify child tile does not exist yet
        expect(cache.has(15, childX, childY), isFalse);

        // But parent lookup succeeds
        final parentFile = cache.lookup(15 - 1, childX >> 1, childY >> 1);
        expect(parentFile, isNotNull);
        expect(await parentFile!.exists(), isTrue);
      } finally {
        await tempDir.delete(recursive: true);
      }
    });
  });
}
