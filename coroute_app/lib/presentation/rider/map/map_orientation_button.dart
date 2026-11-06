import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import 'nav_camera_controller.dart';

/// Round map button (same look as the zoom buttons) that switches the riding
/// map between "direction of travel up" and "north up". Its needle always
/// points north on the map; teal while the map turns with the ride.
class MapOrientationButton extends StatelessWidget {
  final NavCameraController controller;

  const MapOrientationButton({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[controller, controller.mapRotation]),
      builder: (context, _) {
        final courseUp = controller.courseUp;
        final angle = controller.mapRotation.value * math.pi / 180.0;
        final label = courseUp ? 'Map turns with your direction. Tap for north up' : 'North up. Tap to turn the map with your direction';
        return Tooltip(
          message: courseUp ? 'Direction up' : 'North up',
          child: Semantics(
            button: true,
            label: label,
            excludeSemantics: true,
            child: Material(
              key: const Key('cockpit_map_orientation_button'),
              color: AppTheme.card.withAlpha(230),
              borderRadius: BorderRadius.circular(24),
              elevation: 4,
              child: InkWell(
                borderRadius: BorderRadius.circular(24),
                onTap: () {
                  controller.toggleOrientation();
                  if (!controller.following) controller.resumeFollow();
                },
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: Center(
                    child: Transform.rotate(
                      angle: angle.isFinite ? angle : 0.0,
                      child: Icon(
                        courseUp ? Icons.navigation_rounded : Icons.north_rounded,
                        color: courseUp ? AppTheme.brand : AppTheme.text,
                        size: 22,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
