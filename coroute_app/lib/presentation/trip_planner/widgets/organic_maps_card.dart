import 'package:flutter/material.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/ui/ui.dart';
import '../../../data/models/route_model.dart';
import '../../../data/services/offline_nav_service.dart';

/// A card displayed during trip creation (Trip Planner and Trip Review)
/// integrating companion Organic Maps offline navigation and on-demand
/// regional vector map pre-downloading.
class OrganicMapsCard extends StatefulWidget {
  final RouteModel? route;
  final String tripName;
  final (double lat, double lng)? startPoint;
  final String? startName;
  final (double lat, double lng)? destinationPoint;
  final String? destinationName;
  final List<(String name, double lat, double lng)> checkpoints;

  const OrganicMapsCard({
    super.key,
    required this.route,
    this.tripName = 'Planned Route',
    this.startPoint,
    this.startName,
    this.destinationPoint,
    this.destinationName,
    this.checkpoints = const [],
  });

  @override
  State<OrganicMapsCard> createState() => _OrganicMapsCardState();
}

class _OrganicMapsCardState extends State<OrganicMapsCard> with WidgetsBindingObserver {
  bool _isInstalled = false;
  bool _checking = true;
  bool _syncing = false;
  bool _openingDownload = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkStatus();
    }
  }

  Future<void> _checkStatus() async {
    final installed = await OfflineNavService.isInstalled();
    if (mounted) {
      setState(() {
        _isInstalled = installed;
        _checking = false;
      });
    }
  }

  Future<void> _handleDownloadRegion() async {
    if (_openingDownload) return;
    final r = widget.route;
    if (r == null || r.points.isEmpty) return;

    // Use destination point or last point of route
    final dest = widget.destinationPoint ?? r.points.last;
    setState(() => _openingDownload = true);
    try {
      final ok = await OfflineNavService.openOrganicMapsRegionDownload(
        lat: dest.$1,
        lng: dest.$2,
        label: widget.destinationName ?? widget.tripName,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              ok
                  ? 'Opening Organic Maps: tap "Download Map" if prompted.'
                  : 'Unable to launch Organic Maps. Please verify installation.',
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _openingDownload = false);
    }
  }

  Future<void> _handleSyncRoute() async {
    if (_syncing) return;
    final r = widget.route;
    if (r == null || r.points.isEmpty) return;

    setState(() => _syncing = true);
    try {
      final ok = await OfflineNavService.exportRouteToOrganicMaps(
        tripName: widget.tripName,
        points: r.points,
        checkpoints: widget.checkpoints,
      );
      if (mounted && ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Route and waypoints exported. Open in Organic Maps to download regional map.'),
            duration: Duration(seconds: 4),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _handleInstall() async {
    await OfflineNavService.openStoreInstall();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.route;
    if (r == null || r.approximate || r.points.length < 2) {
      return const SizedBox.shrink();
    }

    if (_checking) {
      return const SizedBox.shrink();
    }

    if (!_isInstalled) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.border, width: 1.5),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.soft,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.map_outlined, color: AppTheme.accentText, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          'Organic Maps Companion',
                          style: AppText.headline.copyWith(fontSize: 15),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppTheme.soft,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'OFFLINE',
                          style: AppText.caption.copyWith(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: AppTheme.accentText,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '100% offline vector maps & turn-by-turn voice routing in dead zones.',
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
              onPressed: _handleInstall,
              icon: const Icon(Icons.download_rounded, size: 16),
              label: const Text('Install', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
            ),
          ],
        ),
      );
    }

    // Organic Maps IS INSTALLED: Show rich offline vector controls
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.brand.withValues(alpha: 0.35), width: 1.5),
        boxShadow: dsFloatingShadow(),
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
                  color: AppTheme.brand.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.navigation_rounded, color: AppTheme.brand, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            'Organic Maps Offline',
                            style: AppText.headline.copyWith(fontSize: 15),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppTheme.brand.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'READY',
                            style: AppText.caption.copyWith(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: AppTheme.brand,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Pre-download regional maps or sync route track for cellular dead zones.',
                      style: AppText.caption,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.text,
                    side: BorderSide(color: AppTheme.border),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    minimumSize: const Size(0, 36),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: _openingDownload ? null : _handleDownloadRegion,
                  icon: _openingDownload
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(Icons.downloading_rounded, size: 16, color: AppTheme.brand),
                  label: const Text(
                    'Download Map',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.text,
                    side: BorderSide(color: AppTheme.border),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    minimumSize: const Size(0, 36),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: _syncing ? null : _handleSyncRoute,
                  icon: _syncing
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(Icons.alt_route_rounded, size: 16, color: AppTheme.accentText),
                  label: const Text(
                    'Sync Route GPX',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
