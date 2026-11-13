import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_motion.dart';
import 'skeleton.dart';

/// Pixel size to decode an image shown at [logical] dp: the size on screen
/// times the pixel ratio (capped at 3x), rounded up to a step of 32 so nearly
/// equal sizes share one cache entry. Decoding a 4000 px photo for a 44 dp
/// avatar wastes memory and time; this is the fix.
int decodeSize(double logical, double devicePixelRatio) {
  final dpr = devicePixelRatio.clamp(1.0, 3.0);
  final px = (logical * dpr).ceil();
  return ((px + 31) ~/ 32) * 32;
}

/// A network image that is decoded at the size it is shown, shows a grey
/// placeholder of the same size while loading (no layout jump), fades in and
/// falls back to [fallback] on error. The image cache keeps it for the next
/// screen (same URL + same decode size).
class AppNetworkImage extends StatelessWidget {
  final String url;
  final double width;
  final double height;
  final BoxFit fit;
  final Map<String, String>? headers;
  final BorderRadius? borderRadius;
  final bool circle;
  final Widget? fallback;
  final String? semanticLabel;

  const AppNetworkImage(
    this.url, {
    super.key,
    required this.width,
    required this.height,
    this.fit = BoxFit.cover,
    this.headers,
    this.borderRadius,
    this.circle = false,
    this.fallback,
    this.semanticLabel,
  });

  /// The provider with the sized decode, for DecorationImage / precacheImage.
  static ImageProvider provider(String url, {required double logicalWidth, required double devicePixelRatio, Map<String, String>? headers}) =>
      ResizeImage.resizeIfNeeded(decodeSize(logicalWidth, devicePixelRatio), null, NetworkImage(url, headers: headers));

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final fade = AppMotion.durationOf(context, AppMotion.medium);
    final placeholder = SkeletonBox(width: width, height: height, circle: circle, radius: borderRadius?.topLeft.x ?? 0);
    final fb = fallback ??
        Container(
          width: width,
          height: height,
          color: AppTheme.tint,
          alignment: Alignment.center,
          child: Icon(Icons.image_not_supported_outlined, size: (width < height ? width : height) * 0.4, color: AppTheme.muted),
        );
    Widget img = url.isEmpty
        ? fb
        : Image.network(
            url,
            width: width,
            height: height,
            fit: fit,
            headers: headers,
            // Decode by the longer need only on one axis so the aspect ratio is kept.
            cacheWidth: decodeSize(width, dpr),
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            semanticLabel: semanticLabel,
            excludeFromSemantics: semanticLabel == null,
            frameBuilder: (ctx, child, frame, sync) {
              if (sync || fade == Duration.zero) return child;
              return Stack(
                fit: StackFit.passthrough,
                children: [
                  if (frame == null) placeholder,
                  AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: fade, curve: AppMotion.standard, child: child),
                ],
              );
            },
            errorBuilder: (_, _, _) => fb,
          );
    img = SizedBox(width: width, height: height, child: img);
    if (circle) return ClipOval(child: img);
    final r = borderRadius;
    return r == null ? img : ClipRRect(borderRadius: r, child: img);
  }
}

/// Shared-element flight between two screens (avatar in a list -> profile
/// header, ride card -> trip report). Same [tag] on both screens. With reduce
/// motion there is no flight. The flying widget keeps its shape (Material).
class AppHero extends StatelessWidget {
  final Object tag;
  final Widget child;
  const AppHero({super.key, required this.tag, required this.child});

  /// Tags, so both ends agree.
  static String avatar(String userKey) => 'avatar:$userKey';
  static String rideCard(String rideId) => 'ride:$rideId';

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reducedOf(context)) return child;
    return Hero(
      tag: tag,
      // The user-gesture flight keeps both ends in step with an edge-swipe back.
      transitionOnUserGestures: true,
      flightShuttleBuilder: (_, _, _, _, to) => Material(type: MaterialType.transparency, child: to.widget),
      child: Material(type: MaterialType.transparency, child: child),
    );
  }
}

/// An app bar the content scrolls under: translucent with a blur, a hairline
/// appears once something is under it. The blur is one small layer at the
/// top; with battery saver / reduce motion it is a plain opaque bar.
class FrostedAppBar extends StatelessWidget implements PreferredSizeWidget {
  final Widget? title;
  final List<Widget>? actions;
  final Widget? leading;
  final PreferredSizeWidget? bottom;
  final bool centerTitle;
  const FrostedAppBar({super.key, this.title, this.actions, this.leading, this.bottom, this.centerTitle = false});

  @override
  Size get preferredSize => Size.fromHeight(kToolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) {
    final plain = AppMotion.reducedOf(context);
    final bar = AppBar(
      title: title,
      actions: actions,
      leading: leading,
      bottom: bottom,
      centerTitle: centerTitle,
      backgroundColor: plain ? AppTheme.bg : AppTheme.bg.withValues(alpha: 0.78),
      elevation: 0,
      scrolledUnderElevation: 0,
      shape: Border(bottom: BorderSide(color: AppTheme.border.withValues(alpha: 0.6))),
    );
    if (plain) return bar;
    return ClipRect(
      child: BackdropFilter(filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14), child: bar),
    );
  }
}
