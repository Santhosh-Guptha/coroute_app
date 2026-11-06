import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/map_places_service.dart';
import '../../domain/places/fuel_match.dart';
import '../../domain/places/place_poi.dart';
import '../../domain/places/poi_category.dart';
import '../ride/navigate_to.dart';
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
    return Padding(
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
