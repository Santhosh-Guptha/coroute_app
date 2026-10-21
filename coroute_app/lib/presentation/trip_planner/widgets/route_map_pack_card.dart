import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';
import '../../../core/config/feature_gates.dart';
import '../../../core/constants/safety_constants.dart';
import '../../../data/local/saved_map_pack_store.dart';
import '../../../data/models/route_model.dart';
import '../../../data/services/tile_cache_service.dart';
import '../offline_map_manager_screen.dart';
import '../offline_tile_verification_screen.dart';

/// A card displayed in Trip Planner and Review that downloads the full OSM raster
/// tile corridor along a planned route into local storage (TileCacheService) for
/// offline use in cellular dead zones.
/// Supports standard corridor tiles (zooms 12 & 14) and high-detail mode (zooms 16 & 17)
/// with sharp street names, junction labels, and landmarks.
class RouteMapPackCard extends StatefulWidget {
  final RouteModel? route;
  final String tripName;

  const RouteMapPackCard({
    super.key,
    required this.route,
    this.tripName = 'Route Map Pack',
  });

  @override
  State<RouteMapPackCard> createState() => _RouteMapPackCardState();
}

class _RouteMapPackCardState extends State<RouteMapPackCard> {
  bool _highDetail = true;

  @override
  Widget build(BuildContext context) {
    final r = widget.route;
    if (r == null || r.approximate || r.points.length < 2) {
      return const SizedBox.shrink();
    }

    final points = r.points;
    final prefetcher = context.watch<TilePrefetcher?>();
    if (prefetcher == null) return const SizedBox.shrink();

    final allTiles = TilePrefetcher.tilesAlong(points, highDetail: _highDetail);
    final totalCount = allTiles.length;
    if (totalCount == 0) return const SizedBox.shrink();

    final isCached = prefetcher.isRouteCached(points, highDetail: _highDetail);
    final isRunning = prefetcher.running;
    final hasError = prefetcher.error != null;

    if (isRunning) {
      final done = prefetcher.done;
      final total = prefetcher.total > 0 ? prefetcher.total : totalCount;
      final progress = (done / total).clamp(0.0, 1.0);
      final pct = (progress * 100).toInt();

      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.brand.withValues(alpha: 0.5), width: 1.5),
          boxShadow: dsFloatingShadow(),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppTheme.brand.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: AppTheme.brand,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Downloading Map Pack...',
                        style: AppText.headline.copyWith(fontSize: 15),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$done of $total tiles ($pct%)',
                        style: AppText.caption.copyWith(color: AppTheme.brand, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, size: 20),
                  color: AppTheme.muted,
                  tooltip: 'Cancel download',
                  onPressed: prefetcher.cancel,
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: AppTheme.border,
                color: AppTheme.brand,
                minHeight: 6,
              ),
            ),
          ],
        ),
      );
    }

    if (isCached) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.brand.withValues(alpha: 0.3), width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppTheme.brand.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.offline_pin_rounded, color: AppTheme.brand, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Route Map Pack Downloaded',
                        style: AppText.headline.copyWith(fontSize: 15),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$totalCount OSM tiles saved · Offline ready for 30 days',
                        style: AppText.caption.copyWith(color: AppTheme.muted),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.brand.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'SAVED',
                    style: AppText.caption.copyWith(
                      color: AppTheme.brand,
                      fontWeight: FontWeight.w800,
                      fontSize: 11,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.brand,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      minimumSize: const Size(0, 36),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.remove_red_eye_rounded, size: 16),
                    label: const Text('Verify Offline', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => OfflineTileVerificationScreen(
                            packName: widget.tripName,
                            routePoints: points,
                            highDetail: _highDetail,
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.accentText,
                    side: BorderSide(color: AppTheme.border),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    minimumSize: const Size(0, 36),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  icon: const Icon(Icons.folder_open_rounded, size: 16),
                  label: const Text('Manage Packs', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const OfflineMapManagerScreen(),
                      ),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      );
    }

    if (hasError) {
      final isEntitlement = prefetcher.error == 'entitlement_required';
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isEntitlement ? AppTheme.warnText : AppTheme.warnText.withValues(alpha: 0.4),
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.warnTint,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                isEntitlement ? Icons.lock_rounded : Icons.cloud_off_rounded,
                color: AppTheme.warnText,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isEntitlement ? 'Offline Pack Limit Reached' : 'Download Interrupted',
                    style: AppText.headline.copyWith(fontSize: 15),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isEntitlement
                        ? 'Community tier allows 1 pack. Switch to CoRoute Pro for unlimited corridor downloads.'
                        : 'Network issue. Tap retry to resume.',
                    style: AppText.caption,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (isEntitlement)
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  minimumSize: const Size(0, 36),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () => FeatureGates.showUpgradeModal(context, Feature.unlimitedOfflinePacks),
                child: const Text('Upgrade', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              )
            else
              TextButton(
                onPressed: () => prefetcher.start(points, label: widget.tripName, highDetail: _highDetail),
                child: const Text('Retry'),
              ),
          ],
        ),
      );
    }

    // Idle: ready to download
    final cached = prefetcher.countCachedTiles(points, highDetail: _highDetail);
    final remaining = (totalCount - cached).clamp(0, totalCount);
    final estMb = (remaining * 25 / 1024).toStringAsFixed(1);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.border, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppTheme.soft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.download_for_offline_rounded, color: AppTheme.accentText, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Download Route Map Pack',
                      style: AppText.headline.copyWith(fontSize: 15),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$remaining tiles along route corridor (~$estMb MB)',
                      style: AppText.caption,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  minimumSize: const Size(0, 36),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () async {
                  if (!FeatureGates.isUnlocked(Feature.unlimitedOfflinePacks)) {
                    final existingPacks = await SavedMapPackStore.loadAll();
                    if (existingPacks.length >= SafetyConstants.freeOfflinePacksLimit &&
                        !existingPacks.any((p) => p.name == widget.tripName)) {
                      if (context.mounted) {
                        FeatureGates.showUpgradeModal(context, Feature.unlimitedOfflinePacks);
                      }
                      return;
                    }
                  }
                  prefetcher.start(points, label: widget.tripName, highDetail: _highDetail);
                },
                icon: const Icon(Icons.download_rounded, size: 16),
                label: const Text('Download', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // High Detail Toggle Row
          InkWell(
            onTap: () => setState(() => _highDetail = !_highDetail),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: Checkbox(
                      value: _highDetail,
                      activeColor: AppTheme.brand,
                      onChanged: (val) => setState(() => _highDetail = val ?? true),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'High Detail with Street & Junction Labels (Zooms 16 & 17)',
                      style: AppText.caption.copyWith(
                        color: _highDetail ? AppTheme.brand : AppTheme.accentText,
                        fontWeight: _highDetail ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.folder_open_rounded, size: 18),
                    color: AppTheme.muted,
                    tooltip: 'Manage saved packs',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const OfflineMapManagerScreen(),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
