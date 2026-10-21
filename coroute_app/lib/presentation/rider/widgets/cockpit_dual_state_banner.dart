import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui_tokens.dart';

/// High-visibility dual-state offline HUD banner for the cockpit map.
///
/// Designed for riders wearing thick motorcycle gloves:
/// - Generous glove-friendly padding and oversized tap area (min 48 dp height).
/// - High-contrast typography optimized for harsh direct sunlight.
/// - Dual offline states:
///   1. Cached on disk: `[ 🗺️ OFFLINE · PACK ACTIVE | 📶 X P2P Peers ]` with neon teal outline.
///   2. Uncached / missing corridor tiles: `[ ⚠️ OFFLINE · TERRAIN UNCACHED ]` with amber warning outline.
class CockpitDualStateBanner extends StatelessWidget {
  /// Whether the route and 2.5km corridor tiles are cached on disk.
  final bool isPackActive;

  /// Count of nearby connected P2P mesh peers (via Wi-Fi Direct / BLE).
  final int peerCount;

  /// Whether the rider is currently offline (no cellular data). Defaults to `true`.
  final bool isOffline;

  /// Optional tap callback (e.g. opens offline corridor manager or diagnostics).
  final VoidCallback? onTap;

  /// Optional action callback when uncached (e.g. retry prefetch or download).
  final VoidCallback? onPrefetch;

  /// Outer margin around the banner.
  final EdgeInsetsGeometry? margin;

  const CockpitDualStateBanner({
    super.key,
    required this.isPackActive,
    this.peerCount = 0,
    this.isOffline = true,
    this.onTap,
    this.onPrefetch,
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    if (!isOffline) {
      return const SizedBox.shrink();
    }

    final outlineColor = isPackActive ? AppTheme.neonCyan : AppTheme.hyperAmber;
    final glowColor = isPackActive
        ? AppTheme.neonCyan.withValues(alpha: 0.22)
        : AppTheme.hyperAmber.withValues(alpha: 0.25);

    final semanticText = isPackActive
        ? 'Offline mode: Offline pack active, $peerCount peer-to-peer mesh peers connected'
        : 'Warning: Offline mode, corridor terrain uncached';

    return Semantics(
      container: true,
      button: onTap != null || onPrefetch != null,
      label: semanticText,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: isPackActive ? onTap : (onPrefetch ?? onTap),
        child: Container(
          margin: margin ?? const EdgeInsets.symmetric(horizontal: Space.s12, vertical: Space.s4),
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: Space.s16, vertical: Space.s12),
          decoration: BoxDecoration(
            color: AppTheme.obsidianVoid.withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border.all(color: outlineColor, width: 2.0),
            boxShadow: [
              BoxShadow(
                color: glowColor,
                blurRadius: 10,
                spreadRadius: 1,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: isPackActive
              ? _buildPackActiveContent(context)
              : _buildUncachedContent(context),
        ),
      ),
    );
  }

  Widget _buildPackActiveContent(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Map Pack Status Pill
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '🗺️',
              textScaler: TextScaler.noScaling,
              style: TextStyle(fontSize: 15),
            ),
            const SizedBox(width: Space.s8),
            Text(
              'OFFLINE · PACK ACTIVE',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                color: AppTheme.neonCyan,
                fontSize: 13,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.8,
                fontFamily: AppTheme.fontFamily,
              ),
            ),
          ],
        ),
        // High-contrast vertical divider
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.s12),
          child: Text(
            '|',
            textScaler: TextScaler.noScaling,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.35),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        // P2P Mesh Peers Pill
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '📶',
              textScaler: TextScaler.noScaling,
              style: TextStyle(fontSize: 15),
            ),
            const SizedBox(width: Space.s8),
            Text(
              '$peerCount P2P Peers',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textScaler: TextScaler.noScaling,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
                fontFamily: AppTheme.fontFamily,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildUncachedContent(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.max,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Text(
          '⚠️',
          textScaler: TextScaler.noScaling,
          style: TextStyle(fontSize: 16),
        ),
        const SizedBox(width: Space.s8),
        Flexible(
          child: Text(
            'OFFLINE · TERRAIN UNCACHED',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textScaler: TextScaler.noScaling,
            style: TextStyle(
              color: AppTheme.hyperAmber,
              fontSize: 13,
              fontWeight: FontWeight.w900,
              letterSpacing: 0.8,
              fontFamily: AppTheme.fontFamily,
            ),
          ),
        ),
        if (onPrefetch != null) ...[
          const SizedBox(width: Space.s8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppTheme.hyperAmber.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: AppTheme.hyperAmber, width: 1),
            ),
            child: Text(
              'CACHE',
              textScaler: TextScaler.noScaling,
              style: TextStyle(
                color: AppTheme.hyperAmber,
                fontSize: 11,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.6,
              ),
            ),
          ),
        ],
      ],
    );
  }
}
