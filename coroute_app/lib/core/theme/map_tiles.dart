import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import '../../data/services/tile_cache_service.dart';
import '../constants/app_constants.dart';
import 'app_theme.dart';

/// Dims map tiles in the dark theme so a night ride is not a bright white
/// screen (easier on the eyes, and an OLED screen draws less power).
Widget Function(BuildContext, Widget, TileImage)? get mapTileBuilder => AppTheme.isLight ? null : darkModeTileBuilder;

/// The tile source every map uses (3.16): tiles saved on the phone first, the
/// network after, both with the app's User-Agent. Plain network when the cache
/// could not be opened.
TileProvider appTileProvider() => TileCache.instance == null
    ? NetworkTileProvider(headers: {'User-Agent': AppConstants.osmUserAgent})
    : CachedTileProvider(cache: TileCache.instance);

/// The OSM tile layer for every map: theme-aware tiles through [appTileProvider].
/// [panBuffer] 0 under data saver (no extra ring of tiles around the screen).
TileLayer appTileLayer({int panBuffer = 1}) => TileLayer(
      tileBuilder: mapTileBuilder,
      urlTemplate: AppConstants.osmTileUrl,
      userAgentPackageName: AppConstants.osmUserAgent,
      tileProvider: appTileProvider(),
      panBuffer: panBuffer,
    );
