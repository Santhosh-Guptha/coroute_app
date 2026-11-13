import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/private_places_store.dart';
import '../../domain/privacy/private_places.dart';
import '../map_picker/map_picker_screen.dart';

/// 3.56 (round 6): "Private places" on the Road safety screen. Up to three places set on a map and
/// kept only on this phone; rides are not recorded within 300 m of them.
class PrivatePlacesCard extends StatefulWidget {
  const PrivatePlacesCard({super.key});

  static const String title = 'Private places';
  static const String explain =
      'Mark up to 3 places such as home or work. Within 300 m of them your route is not recorded, so it is missing from trip reports, shared trip links and the anonymous road data. '
      'They stay on this phone only. Your live position during a ride is not hidden: your group, your guardian and an SOS always get your real position.';

  @override
  State<PrivatePlacesCard> createState() => _PrivatePlacesCardState();
}

class _PrivatePlacesCardState extends State<PrivatePlacesCard> {
  final PrivatePlacesStore _store = PrivatePlacesStore.shared;
  static const List<String> _labels = ['Home', 'Work', 'Other place'];

  @override
  void initState() {
    super.initState();
    _store.addListener(_changed);
    _store.load().ignore();
  }

  @override
  void dispose() {
    _store.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _add() async {
    final used = {for (final p in _store.places) p.label};
    final label = _labels.firstWhere((l) => !used.contains(l), orElse: () => 'Place ${_store.places.length + 1}');
    final picked = await MapPickerScreen.pick(context, title: 'Private place: $label', confirmLabel: 'Hide rides near here');
    if (picked == null || !mounted) return;
    final ok = await _store.add(PrivatePlace(label: label, lat: picked.lat, lng: picked.lng));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(ok ? '$label saved on this phone.' : 'You can keep up to ${PrivatePlaces.maxPlaces} private places.')));
  }

  @override
  Widget build(BuildContext context) {
    final places = _store.places;
    return DsCard(
      padding: const EdgeInsets.symmetric(horizontal: Space.s16, vertical: Space.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(PrivatePlacesCard.explain, style: AppText.caption.copyWith(color: AppTheme.text2)),
          for (var i = 0; i < places.length; i++)
            ListTile(
              key: ValueKey('private_place_$i'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.shield_moon_outlined, color: AppTheme.accent),
              title: Text(places[i].label.isEmpty ? 'Place ${i + 1}' : places[i].label, style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
              subtitle: Text('Rides are hidden within 300 m', style: AppText.caption),
              trailing: IconButton(
                tooltip: 'Remove ${places[i].label}',
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: () => _store.removeAt(i),
              ),
            ),
          const SizedBox(height: Space.s8),
          if (!_store.isFull)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('private_place_add'),
                onPressed: _add,
                icon: const Icon(Icons.add_location_alt_outlined),
                label: Text(places.isEmpty ? 'Add a private place' : 'Add another place'),
              ),
            )
          else
            Text('You have ${PrivatePlaces.maxPlaces} private places. Remove one to add another.', style: AppText.caption),
        ],
      ),
    );
  }
}
