import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'app_theme.dart';

/// Dims map tiles in the dark theme so a night ride is not a bright white
/// screen (easier on the eyes, and an OLED screen draws less power).
Widget Function(BuildContext, Widget, TileImage)? get mapTileBuilder => AppTheme.isLight ? null : darkModeTileBuilder;
