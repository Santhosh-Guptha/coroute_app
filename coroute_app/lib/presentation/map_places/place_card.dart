import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/map_places_service.dart';
import '../../data/services/place_review_service.dart';
import '../../domain/places/fuel_match.dart';
import '../../domain/places/place_poi.dart';
import '../../domain/places/poi_category.dart';
import '../ride/navigate_to.dart';
import 'place_review_sheet.dart';
import '../widgets/feature_switch.dart';
import 'place_style.dart';

String _km(double km) => km < 1 ? '${(km * 1000).round()} m' : km < 10 ? '${km.toStringAsFixed(1)} km' : '${km.round()} km';

/// Bottom card for one place: name, kind, distance, hours, call and navigate.
Future<void> showPlaceCard(BuildContext context, PlacePoi poi, MapPlacesService service) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    backgroundColor: AppTheme.card,
    constraints: const BoxConstraints(maxWidth: 600),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    isScrollControlled: true,
    builder: (_) => PlaceCard(poi: poi, service: service),
  );
}

class PlaceCard extends StatelessWidget {
  const PlaceCard({super.key, required this.poi, required this.service});
  final PlacePoi poi;
  final MapPlacesService service;

  @override
  Widget build(BuildContext context) {
    final d = service.distanceTo(poi);
    final distance = d.aheadKm != null
        ? '${_km(d.aheadKm!)} ahead on your route'
        : d.straightKm.isFinite
            ? '${_km(d.straightKm)} away'
            : null;
    final hours = poi.open24h ? 'Open 24 hours' : poi.openingHours;
    final isStation = poi.category == PoiCategory.fuel || poi.category == PoiCategory.ev;
    final match = isStation ? fuelMatch(poi, service.fuelType) : null;
    final phone = poi.phone;
    final badges = <(String, Color)>[
      if (poi.isEmergencyHospital) ('24h emergency', AppTheme.sos),
      if (match == FuelMatch.match) ('Has ${service.fuelType.label.toLowerCase()}', poi.category.color),
      if (match == FuelMatch.unknown) ('Fuel type unknown', AppTheme.warnText),
    ];
    final reviews = context.read<PlaceReviewService?>();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Space.s24, Space.s16, Space.s24, Space.s24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            CircleAvatar(radius: 22, backgroundColor: poi.category.color, child: Icon(poi.category.icon, color: Colors.white)),
            const SizedBox(width: Space.s12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(poi.displayName, style: AppText.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                Text(poi.category.singular, style: AppText.caption.copyWith(color: AppTheme.muted)),
              ]),
            ),
          ]),
          if (badges.isNotEmpty) ...[
            const SizedBox(height: Space.s12),
            Wrap(spacing: Space.s8, runSpacing: Space.s4, children: [
              for (final (text, color) in badges)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
                  child: Text(text, style: AppText.caption.copyWith(color: color, fontWeight: FontWeight.w700)),
                ),
            ]),
          ],
          const SizedBox(height: Space.s12),
          if (distance != null) _line(Icons.near_me_rounded, distance),
          _line(Icons.schedule_rounded, hours ?? 'Opening hours not known'),
          if (phone != null) _line(Icons.call_rounded, phone),
          const SizedBox(height: Space.s16),
          Row(children: [
            if (phone != null) ...[
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('placeCall'),
                  onPressed: () => launchUrl(Uri(scheme: 'tel', path: phone)),
                  icon: const Icon(Icons.call_rounded),
                  label: const Text('Call'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
                ),
              ),
              const SizedBox(width: Space.s12),
            ],
            Expanded(
              child: FilledButton.icon(
                key: const ValueKey('placeNavigate'),
                onPressed: () => navigateTo(poi.lat, poi.lng, label: poi.displayName),
                icon: const Icon(Icons.navigation_rounded),
                label: const Text('Navigate'),
                style: FilledButton.styleFrom(minimumSize: const Size(0, 48), backgroundColor: AppTheme.brand),
              ),
            ),
          ]),
          // 3.55: CoRoute rider ratings, reviews and approved photos, and "Rate this place".
          // 3.55 admin feature switch: place reviews turned off for every rider.
          if (reviews != null && context.featureOn('placeReviews')) PlaceRiderReviews(poi: poi, reviews: reviews),
          const SizedBox(height: Space.s8),
          Text('Map data © OpenStreetMap contributors', textAlign: TextAlign.center, style: AppText.caption.copyWith(color: AppTheme.muted, fontSize: 10)),
        ],
      ),
    );
  }

  Widget _line(IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(bottom: Space.s4),
        child: Row(children: [
          Icon(icon, size: 16, color: AppTheme.muted),
          const SizedBox(width: Space.s8),
          Expanded(child: Text(text, style: AppText.body.copyWith(color: AppTheme.text2))),
        ]),
      );
}

/// 3.55: "CoRoute riders" in the place card: ★ average and count, the latest reviews (first name,
/// stars, text, how long ago), approved photos, and "Rate this place" (any time).
class PlaceRiderReviews extends StatefulWidget {
  const PlaceRiderReviews({super.key, required this.poi, required this.reviews});
  final PlacePoi poi;
  final PlaceReviewService reviews;

  @override
  State<PlaceRiderReviews> createState() => _PlaceRiderReviewsState();
}

class _PlaceRiderReviewsState extends State<PlaceRiderReviews> {
  PlaceReviewsPage? _page;
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool force = false}) async {
    try {
      final page = await widget.reviews.reviewsFor(widget.poi.id, force: force);
      if (!mounted) return;
      setState(() {
        _page = page;
        _loading = false;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  Future<void> _rate() async {
    final sent = await showPlaceReviewSheet(context, place: widget.poi, service: widget.reviews, mine: _page?.mine);
    if (sent == true && mounted) _load(force: true);
  }

  static String _ago(int at) {
    if (at <= 0) return '';
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(at));
    if (d.inDays >= 365) return '${d.inDays ~/ 365} y ago';
    if (d.inDays >= 30) return '${d.inDays ~/ 30} mo ago';
    if (d.inDays >= 1) return '${d.inDays} d ago';
    if (d.inHours >= 1) return '${d.inHours} h ago';
    return 'just now';
  }

  Widget _stars(int n, {double size = 14}) => Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 1; i <= 5; i++) Icon(i <= n ? Icons.star_rounded : Icons.star_outline_rounded, size: size, color: AppTheme.hyperAmber),
      ]);

  @override
  Widget build(BuildContext context) {
    final page = _page;
    final s = page?.summary;
    final photos = <String>[for (final r in page?.reviews ?? const <PlaceReviewItem>[]) ...r.photos].take(6).toList();
    final mine = page?.mine;
    return Padding(
      padding: const EdgeInsets.only(top: Space.s16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Flexible(child: Semantics(header: true, child: Text('CoRoute rider reviews', maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(fontWeight: FontWeight.w800)))),
          const SizedBox(width: Space.s8),
          if (s != null) ...[
            Icon(Icons.star_rounded, size: 18, color: AppTheme.hyperAmber),
            Text(' ${s.avg.toStringAsFixed(1)}', style: AppText.label.copyWith(fontWeight: FontWeight.w800)),
            Text('  ·  ${s.count} rating${s.count == 1 ? '' : 's'}', style: AppText.caption.copyWith(color: AppTheme.muted)),
          ],
        ]),
        const SizedBox(height: Space.s8),
        if (_loading)
          const Padding(padding: EdgeInsets.all(Space.s8), child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))))
        else if (_failed)
          Text('Ratings could not load. Check your connection.', style: AppText.caption.copyWith(color: AppTheme.muted))
        else if (s == null)
          Text('No ratings yet. Be the first to help the riders coming after you.', style: AppText.caption.copyWith(color: AppTheme.muted)),
        if (photos.isNotEmpty) ...[
          SizedBox(
            height: 84,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: photos.length,
              separatorBuilder: (_, _) => const SizedBox(width: Space.s8),
              itemBuilder: (_, i) => ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.network(
                  widget.reviews.photoUrl(photos[i]),
                  headers: widget.reviews.photoHeaders,
                  width: 84,
                  height: 84,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(width: 84, height: 84, color: AppTheme.soft, child: Icon(Icons.image_not_supported_outlined, color: AppTheme.muted)),
                ),
              ),
            ),
          ),
          const SizedBox(height: Space.s8),
        ],
        for (final r in (page?.reviews ?? const <PlaceReviewItem>[]).take(3))
          Padding(
            padding: const EdgeInsets.only(bottom: Space.s8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(r.firstName, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(width: Space.s8),
                _stars(r.rating),
                const Spacer(),
                Text(_ago(r.createdAt), style: AppText.caption.copyWith(color: AppTheme.muted)),
              ]),
              if (r.text.isNotEmpty) Text(r.text, style: AppText.body.copyWith(color: AppTheme.text2), maxLines: 4, overflow: TextOverflow.ellipsis),
            ]),
          ),
        if (mine != null && mine.photosPending > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.s8),
            child: Text('Your photo appears after a quick check.', style: AppText.caption.copyWith(color: AppTheme.muted)),
          ),
        OutlinedButton.icon(
          key: const ValueKey('placeRate'),
          onPressed: _rate,
          icon: Icon(mine != null ? Icons.edit_rounded : Icons.star_outline_rounded),
          label: Text(mine != null ? 'Update rating' : 'Rate this place'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
        ),
      ]),
    );
  }
}
