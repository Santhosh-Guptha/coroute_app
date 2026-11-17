import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/private_places_store.dart';
import '../../domain/privacy/private_places.dart';
import '../map_picker/map_picker_screen.dart';

/// v3.63 privacy zones (Profile > Privacy zones). Up to three places (Home, Work, Other) found by search,
/// the current location or a tap on the map, each with a 300 m / 500 m / 1 km radius. Kept only on this
/// phone. Near them nobody sees where you are (group, guardians, ride pages, guests, live links) and the
/// route is not recorded. In an emergency the exact location is always shared.
class PrivacyZonesScreen extends StatefulWidget {
  const PrivacyZonesScreen({super.key});

  static const String title = 'Privacy zones';
  static const String rowSubtitle = 'Hide where you start and end';
  static const String explain =
      'Save up to 3 places such as home or work. Near them nobody can see where you are: not your group, '
      'your guardians, ride pages or live links. Your route there is not recorded either. The places stay on this phone.';
  static const String emergencyNote = 'In an emergency your exact location is always shared.';

  static Future<void> open(BuildContext context) =>
      Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const PrivacyZonesScreen(), settings: const RouteSettings(name: 'privacy/zones')));

  /// "500 m" / "1 km".
  static String radiusText(double m) => m >= 1000 ? '${(m / 1000).toStringAsFixed(m % 1000 == 0 ? 0 : 1)} km' : '${m.round()} m';

  @override
  State<PrivacyZonesScreen> createState() => _PrivacyZonesScreenState();
}

class _PrivacyZonesScreenState extends State<PrivacyZonesScreen> {
  final PrivatePlacesStore _store = PrivatePlacesStore.shared;
  static const List<String> _labels = ['Home', 'Work', 'Other'];
  bool _busy = false;

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
    if (_busy) return;
    final used = {for (final p in _store.places) p.label};
    final label = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final l in _labels)
            ListTile(
              key: ValueKey('privacy_zone_label_$l'),
              enabled: l == 'Other' || !used.contains(l),
              leading: Icon(l == 'Home' ? Icons.home_outlined : l == 'Work' ? Icons.work_outline_rounded : Icons.place_outlined),
              title: Text(l),
              subtitle: l != 'Other' && used.contains(l) ? const Text('Already saved') : null,
              onTap: () => Navigator.pop(ctx, l),
            ),
        ]),
      ),
    );
    if (label == null || !mounted) return;
    _busy = true;
    try {
      // The picker searches addresses, offers the current location and a pin on the map.
      final picked = await MapPickerScreen.pick(context, title: 'Privacy zone: $label', confirmLabel: 'Hide my location here');
      if (picked == null || !mounted) return;
      final ok = await _store.add(PrivatePlace(label: label, lat: picked.lat, lng: picked.lng, radiusM: PrivatePlaces.defaultRadiusM));
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text(ok ? '$label saved on this phone. Your location is hidden within ${PrivacyZonesScreen.radiusText(PrivatePlaces.defaultRadiusM)}.' : 'You can keep up to ${PrivatePlaces.maxPlaces} places.')));
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final places = _store.places;
    return Scaffold(
      appBar: AppBar(title: const Text(PrivacyZonesScreen.title)),
      body: ListView(
        padding: const EdgeInsets.all(Space.s16),
        children: [
          Text(PrivacyZonesScreen.explain, style: AppText.body.copyWith(color: AppTheme.text2)),
          const SizedBox(height: Space.s12),
          DsCard(
            padding: const EdgeInsets.all(Space.s12),
            child: Row(children: [
              Icon(Icons.sos_rounded, color: AppTheme.sos),
              const SizedBox(width: Space.s12),
              Expanded(child: Text(PrivacyZonesScreen.emergencyNote, key: const Key('privacy_zone_emergency_note'), style: AppText.body.copyWith(fontWeight: FontWeight.w600))),
            ]),
          ),
          const SizedBox(height: Space.s16),
          for (var i = 0; i < places.length; i++) ...[
            DsCard(
              key: ValueKey('privacy_zone_$i'),
              padding: const EdgeInsets.fromLTRB(Space.s16, Space.s8, Space.s4, Space.s12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(places[i].label == 'Home' ? Icons.home_outlined : places[i].label == 'Work' ? Icons.work_outline_rounded : Icons.place_outlined, color: AppTheme.accent),
                  const SizedBox(width: Space.s12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(places[i].label.isEmpty ? 'Place ${i + 1}' : places[i].label, style: AppText.title),
                      Text('Hidden within ${PrivacyZonesScreen.radiusText(places[i].radiusM)}', style: AppText.caption),
                    ]),
                  ),
                  IconButton(
                    key: ValueKey('privacy_zone_remove_$i'),
                    tooltip: 'Remove ${places[i].label}',
                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () => _store.removeAt(i),
                  ),
                ]),
                const SizedBox(height: Space.s8),
                SegmentedButton<double>(
                  key: ValueKey('privacy_zone_radius_$i'),
                  segments: [for (final r in PrivatePlaces.radiusChoices) ButtonSegment(value: r, label: Text(PrivacyZonesScreen.radiusText(r)))],
                  selected: {places[i].radiusM},
                  onSelectionChanged: (v) => _store.setRadius(i, v.first),
                ),
              ]),
            ),
            const SizedBox(height: Space.s12),
          ],
          if (!_store.isFull)
            FilledButton.icon(
              key: const Key('privacy_zone_add'),
              onPressed: _add,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              icon: const Icon(Icons.add_location_alt_outlined),
              label: Text(places.isEmpty ? 'Add a place' : 'Add another place'),
            )
          else
            Text('You have ${PrivatePlaces.maxPlaces} places. Remove one to add another.', style: AppText.caption),
          const SizedBox(height: Space.s16),
          Text('During a ride near a saved place your group sees "Location hidden near a saved place" instead of your position. '
              'Group alerts such as "falling behind" ignore you there.',
              style: AppText.caption),
        ],
      ),
    );
  }
}
