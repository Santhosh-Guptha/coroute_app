import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/config/feature_gates.dart';
import '../../core/constants/safety_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/local/saved_map_pack_store.dart';
import '../../data/models/saved_map_pack.dart';
import '../../data/services/tile_cache_service.dart';
import '../../data/services/plan_subscription_service.dart';
import 'offline_tile_verification_screen.dart';
import 'trip_planner_screen.dart';

/// Offline Map Pack Manager screen displaying storage usage, downloaded
/// corridor map packs, high-detail zoom statuses, one-tap tile verification,
/// and pack deletion.
class OfflineMapManagerScreen extends StatefulWidget {
  final List<SavedMapPack>? initialPacks;
  const OfflineMapManagerScreen({super.key, this.initialPacks});

  @override
  State<OfflineMapManagerScreen> createState() => _OfflineMapManagerScreenState();
}

class _OfflineMapManagerScreenState extends State<OfflineMapManagerScreen> {
  late List<SavedMapPack> _packs = widget.initialPacks ?? [];
  late bool _loading = widget.initialPacks == null;
  bool _isDeleting = false;
  bool _isClearing = false;
  bool _isNavigating = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialPacks == null) {
      _loadPacks();
    }
  }

  Future<void> _loadPacks() async {
    setState(() => _loading = true);
    final packs = await SavedMapPackStore.loadAll();
    if (mounted) {
      setState(() {
        _packs = packs;
        _loading = false;
      });
    }
  }

  Future<void> _deletePack(SavedMapPack pack) async {
    if (_isDeleting) return;
    _isDeleting = true;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.card,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Delete Map Pack?', style: AppText.headline),
          content: Text(
            'Delete "${pack.name}"? Cached tiles will be removed to free storage.',
            style: AppText.body,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.sos),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );

      if (confirmed != true || !mounted) return;

      await SavedMapPackStore.delete(pack.id);

      // Also delete tiles from disk cache if polyline available
      if (pack.polyline.isNotEmpty) {
        final tiles = TilePrefetcher.tilesAlong(
          pack.polyline,
          zooms: pack.zooms,
          highDetail: pack.highDetail,
        );
        await TileCache.instance?.deleteTiles(tiles);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Map pack "${pack.name}" removed'),
          ),
        );
        _loadPacks();
      }
    } finally {
      if (mounted) setState(() => _isDeleting = false);
    }
  }

  Future<void> _clearAll() async {
    if (_isClearing) return;
    _isClearing = true;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.card,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Clear All Offline Map Packs?', style: AppText.headline),
          content: Text(
            'This will purge all downloaded corridor map packs and wipe cached tiles.',
            style: TextStyle(color: AppTheme.text2),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.sos),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Clear All'),
            ),
          ],
        ),
      );

      if (confirmed != true || !mounted) return;

      await SavedMapPackStore.clear();
      await TileCache.instance?.clear();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('All offline map packs and cache cleared'),
          ),
        );
        _loadPacks();
      }
    } finally {
      if (mounted) setState(() => _isClearing = false);
    }
  }

  void _onDownloadNewPack() {
    final isUnlimited = FeatureGates.isUnlocked(Feature.unlimitedOfflinePacks);
    if (!isUnlimited && _packs.length >= SafetyConstants.freeOfflinePacksLimit) {
      FeatureGates.showUpgradeModal(context, Feature.unlimitedOfflinePacks);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const TripPlannerScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    context.watch<PlanSubscriptionService?>();
    final cacheBytes = TileCache.instance?.approxBytes ?? 0;
    final maxBytes = SafetyConstants.tileCacheMaxBytes;
    final usedMb = (cacheBytes / (1024 * 1024)).toStringAsFixed(1);
    final totalMb = (maxBytes / (1024 * 1024)).toInt();
    final usedFraction = (cacheBytes / maxBytes).clamp(0.0, 1.0);
    final tileCount = TileCache.instance?.count ?? 0;

    return Scaffold(
      backgroundColor: AppTheme.bg,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: const Text('Offline Map Packs'),
        backgroundColor: AppTheme.card,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(
              !FeatureGates.isUnlocked(Feature.unlimitedOfflinePacks) && _packs.length >= SafetyConstants.freeOfflinePacksLimit
                  ? Icons.lock_outline_rounded
                  : Icons.add_circle_outline_rounded,
              color: !FeatureGates.isUnlocked(Feature.unlimitedOfflinePacks) && _packs.length >= SafetyConstants.freeOfflinePacksLimit
                  ? AppTheme.warnText
                  : AppTheme.accentText,
            ),
            tooltip: 'Download Corridor Pack',
            onPressed: _onDownloadNewPack,
          ),
          if (_packs.isNotEmpty || tileCount > 0)
            IconButton(
              icon: const Icon(Icons.delete_sweep_rounded),
              tooltip: 'Clear all packs',
              onPressed: _isClearing ? null : _clearAll,
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  physics: const BouncingScrollPhysics(),
                  keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                  children: [
                    // Plan Entitlement Status Banner
                    if (!FeatureGates.isUnlocked(Feature.unlimitedOfflinePacks))
                      Container(
                        margin: const EdgeInsets.only(bottom: 14),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.warnTint,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppTheme.warnBorder, width: 1.5),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.lock_outline_rounded, color: AppTheme.warnText, size: 22),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'COMMUNITY PLAN · 1 PACK LIMIT',
                                    style: TextStyle(color: AppTheme.warnText, fontWeight: FontWeight.w800, fontSize: 12),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${_packs.length} of 1 offline route pack used. Upgrade to CoRoute Pro for unlimited corridor downloads.',
                                    style: TextStyle(color: AppTheme.text2, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: AppTheme.brand,
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                minimumSize: const Size(64, 48),
                              ),
                              onPressed: () => FeatureGates.showUpgradeModal(context, Feature.unlimitedOfflinePacks),
                              child: const Text('Upgrade', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
                            ),
                          ],
                        ),
                      )
                else
                  Container(
                    margin: const EdgeInsets.only(bottom: 14),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppTheme.accentText.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AppTheme.accentText, width: 1.2),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.verified_rounded, color: AppTheme.accentText, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '${FeatureGates.tierLabel(FeatureGates.activeTier).toUpperCase()} · UNLIMITED PACKS ACTIVE',
                            style: TextStyle(color: AppTheme.accentText, fontWeight: FontWeight.w800, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),

                // Storage Gauge Card
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppTheme.card,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppTheme.border, width: 1.5),
                    boxShadow: dsFloatingShadow(),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: AppTheme.brand.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(Icons.sd_storage_rounded, color: AppTheme.brand, size: 20),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Local Map Cache Storage', style: AppText.headline.copyWith(fontSize: 15)),
                                const SizedBox(height: 2),
                                Text(
                                  '$usedMb MB of $totalMb MB used · $tileCount total tiles',
                                  style: AppText.caption,
                                ),
                              ],
                            ),
                          ),
                          Text(
                            '${(usedFraction * 100).toInt()}%',
                            style: AppText.headline.copyWith(
                              fontSize: 15,
                              color: usedFraction > 0.85 ? AppTheme.warnText : AppTheme.brand,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: usedFraction,
                          backgroundColor: AppTheme.border,
                          color: usedFraction > 0.85 ? AppTheme.warnText : AppTheme.brand,
                          minHeight: 8,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),

                // Saved Corridor Packs Header
                Row(
                  children: [
                    Text('DOWNLOADED CORRIDORS', style: AppText.overline),
                    const Spacer(),
                    Text('${_packs.length} packs', style: AppText.caption),
                  ],
                ),

                const SizedBox(height: 10),

                if (_packs.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: AppTheme.card,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: AppTheme.border, width: 1.5),
                    ),
                    child: Column(
                      children: [
                        Icon(Icons.offline_pin_outlined, size: 48, color: AppTheme.muted),
                        const SizedBox(height: 12),
                        Text('No Downloaded Corridors', style: AppText.headline.copyWith(fontSize: 16)),
                        const SizedBox(height: 6),
                        Text(
                          'Plan a route in Trip Planner to download offline map packs with sharp street names, junction labels, and landmarks.',
                          textAlign: TextAlign.center,
                          style: AppText.caption,
                        ),
                      ],
                    ),
                  )
                else
                  ..._packs.map((pack) => _buildPackCard(pack)),
              ],
            ),
        ),
      ),
    );
  }

  Widget _buildPackCard(SavedMapPack pack) {
    final dateStr = '${pack.downloadedAt.day}/${pack.downloadedAt.month}/${pack.downloadedAt.year}';
    final zoomStr = 'Zooms: ${pack.zooms.join(', ')}';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.border, width: 1.5),
        boxShadow: dsFloatingShadow(),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppTheme.brand.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.map_rounded, color: AppTheme.brand, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      pack.name,
                      style: AppText.headline.copyWith(fontSize: 15),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Saved on $dateStr · ${pack.tileCount} tiles (~${pack.sizeMb} MB)',
                      style: AppText.caption,
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: pack.highDetail ? AppTheme.brand.withValues(alpha: 0.15) : AppTheme.soft,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  pack.highDetail ? 'HIGH DETAIL' : 'STANDARD',
                  style: AppText.caption.copyWith(
                    color: pack.highDetail ? AppTheme.brand : AppTheme.accentText,
                    fontWeight: FontWeight.w800,
                    fontSize: 10,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '$zoomStr · Street names, junction labels & landmarks included',
            style: AppText.caption.copyWith(color: AppTheme.accentText, fontSize: 11),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.brand,
                    side: BorderSide(color: AppTheme.brand.withValues(alpha: 0.5)),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    minimumSize: const Size(0, 48),
                  ),
                  icon: const Icon(Icons.remove_red_eye_rounded, size: 16),
                  label: const Text('Verify Offline', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                  onPressed: _isNavigating
                      ? null
                      : () async {
                          setState(() => _isNavigating = true);
                          try {
                            await Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => OfflineTileVerificationScreen(
                                  packName: pack.name,
                                  routePoints: pack.polyline,
                                  highDetail: pack.highDetail,
                                ),
                              ),
                            );
                          } finally {
                            if (mounted) setState(() => _isNavigating = false);
                          }
                        },
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded, size: 20),
                color: AppTheme.sos,
                tooltip: 'Delete map pack',
                onPressed: _isDeleting ? null : () => _deletePack(pack),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
