import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../data/services/map_places_service.dart';
import '../../domain/places/fuel_match.dart';
import '../../domain/places/poi_category.dart';
import 'fuel_ahead_sheet.dart';
import 'place_style.dart';

/// Category chips for map places. Choices are saved on the phone.
class PlaceCategoryChips extends StatelessWidget {
  const PlaceCategoryChips({super.key, required this.service, this.onFuelAhead});
  final MapPlacesService service;

  /// Shown as a "Fuel ahead" chip when set (a route is loaded).
  final VoidCallback? onFuelAhead;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: service,
        builder: (context, _) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(children: [
            if (onFuelAhead != null)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ActionChip(
                  key: const ValueKey('placesFuelAhead'),
                  avatar: Icon(Icons.route_rounded, size: 18, color: AppTheme.brand),
                  label: const Text('Fuel ahead'),
                  onPressed: onFuelAhead,
                ),
              ),
            for (final c in PoiCategory.values)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: FilterChip(
                  key: ValueKey('placeChip_${c.name}'),
                  avatar: Icon(c.icon, size: 18, color: service.isEnabled(c) ? Colors.white : c.color),
                  label: Text(c == PoiCategory.fuel && service.fuelType != BikeFuelType.petrol ? 'Fuel (${service.fuelType.label})' : c.label),
                  selected: service.isEnabled(c),
                  showCheckmark: false,
                  selectedColor: c.color,
                  labelStyle: TextStyle(color: service.isEnabled(c) ? Colors.white : AppTheme.text, fontWeight: FontWeight.w600),
                  backgroundColor: AppTheme.card,
                  side: BorderSide(color: service.isEnabled(c) ? c.color : AppTheme.border),
                  onSelected: (on) => service.setEnabled(c, on),
                ),
              ),
          ]),
        ),
      );
}

/// A small map button that opens and closes the chip row (keeps the ride map clear).
class PlacesToggle extends StatefulWidget {
  const PlacesToggle({super.key, required this.service, this.onFuelAhead, this.initiallyOpen = false});
  final MapPlacesService service;
  final VoidCallback? onFuelAhead;
  final bool initiallyOpen;

  @override
  State<PlacesToggle> createState() => _PlacesToggleState();
}

class _PlacesToggleState extends State<PlacesToggle> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: AppTheme.card,
            shape: const CircleBorder(),
            elevation: 3,
            child: IconButton(
              key: const ValueKey('placesToggle'),
              tooltip: _open ? 'Hide place filters' : 'Places on map',
              icon: Icon(_open ? Icons.close_rounded : Icons.place_rounded, color: AppTheme.brand),
              onPressed: () => setState(() => _open = !_open),
            ),
          ),
          if (_open)
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(left: 6),
                child: PlaceCategoryChips(service: widget.service, onFuelAhead: widget.onFuelAhead),
              ),
            ),
        ],
      );
}

/// Round 44 dp map button: opens the places sheet (category chips, and the
/// stations ahead when a route is loaded).
class PlacesMapButton extends StatelessWidget {
  const PlacesMapButton({super.key, required this.service, this.usableKm, this.marginKm});
  final MapPlacesService service;

  /// Fuel estimate before reserve, and the reserve, for the "Fuel ahead" list (null = not set).
  final double? Function()? usableKm;
  final double Function()? marginKm;

  @override
  Widget build(BuildContext context) => Material(
        color: AppTheme.card,
        shape: const CircleBorder(),
        elevation: 4,
        child: InkWell(
          key: const ValueKey('placesMapButton'),
          customBorder: const CircleBorder(),
          onTap: () => showPlacesSheet(context, service, usableKm: usableKm?.call(), marginKm: marginKm?.call() ?? 0),
          child: SizedBox(
            width: 44,
            height: 44,
            child: Tooltip(message: 'Places on map', child: Icon(Icons.place_rounded, color: AppTheme.brand)),
          ),
        ),
      );
}

/// Places sheet: which categories show on the map, and the stations ahead.
Future<void> showPlacesSheet(BuildContext context, MapPlacesService service, {double? usableKm, double marginKm = 0}) =>
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: AppTheme.card,
      constraints: BoxConstraints(maxWidth: 600, maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => ListenableBuilder(
        listenable: service,
        builder: (ctx, _) => ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            Text('Places on map', style: TextStyle(color: AppTheme.text, fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('Icons show from closer zoom; names when zoomed in further. Choices are saved.',
                style: TextStyle(color: AppTheme.muted, fontSize: 12)),
            const SizedBox(height: 12),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final c in PoiCategory.values)
                FilterChip(
                  key: ValueKey('placeSheetChip_${c.name}'),
                  avatar: Icon(c.icon, size: 18, color: service.isEnabled(c) ? Colors.white : c.color),
                  label: Text(c == PoiCategory.fuel && service.fuelType != BikeFuelType.petrol ? 'Fuel (${service.fuelType.label})' : c.label),
                  selected: service.isEnabled(c),
                  showCheckmark: false,
                  selectedColor: c.color,
                  labelStyle: TextStyle(color: service.isEnabled(c) ? Colors.white : AppTheme.text, fontWeight: FontWeight.w600),
                  backgroundColor: AppTheme.card,
                  side: BorderSide(color: service.isEnabled(c) ? c.color : AppTheme.border),
                  onSelected: (on) => service.setEnabled(c, on),
                ),
            ]),
            if (service.lastError != null) ...[
              const SizedBox(height: 8),
              Text(service.lastError!, style: TextStyle(color: AppTheme.warnText, fontSize: 12)),
            ],
            if (service.hasRoute) ...[
              const SizedBox(height: 8),
              const Divider(),
              FuelAheadList(service: service, usableKm: usableKm, marginKm: marginKm),
            ],
          ],
        ),
      ),
    );
