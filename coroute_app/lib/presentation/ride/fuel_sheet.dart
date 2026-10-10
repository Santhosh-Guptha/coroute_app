import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../../core/ui/ui.dart';

import '../../domain/safety/fuel_profile.dart';

import '../../data/services/settings_service.dart';

import '../../data/services/safety_service.dart';



Future<void> showFuelSheet(BuildContext context, {bool configure = false}) => showAppSheet<void>(context,

  title: configure ? 'Fuel profile' : 'Fuel estimate', isScrollControlled: true,

  builder: (_) => _FuelSheet(settings: context.read<SettingsService>(), safety: context.read<SafetyService?>(), configure: configure));



class _FuelSheet extends StatefulWidget {

  final SettingsService settings;

  final SafetyService? safety;

  final bool configure;

  const _FuelSheet({required this.settings, required this.safety, required this.configure});

  @override

  State<_FuelSheet> createState() => _FuelSheetState();

}

class _FuelSheetState extends State<_FuelSheet> {

  late bool editing, litres;

  late final TextEditingController capacity, mileage, range, reserve, buffer;

  final amount = TextEditingController();

  String? error;

  bool saving = false;

  @override

  void initState() {

    super.initState();

    final p = widget.settings.fuelProfile;

    editing = widget.configure || !p.valid; litres = p.litresMode;

    capacity = TextEditingController(text: '${p.capacityL}'); mileage = TextEditingController(text: '${p.mileageKmL}');

    range = TextEditingController(text: '${p.fullRangeKm}'); reserve = TextEditingController(text: '${litres ? p.reserveL : p.reserveKm}');

    buffer = TextEditingController(text: '${p.bufferKm}');

  }

  @override

  void dispose() { for (final c in [capacity, mileage, range, reserve, buffer, amount]) { c.dispose(); } super.dispose(); }

  double n(TextEditingController c) => double.tryParse(c.text.trim()) ?? double.nan;

  Widget field(String label, TextEditingController c) => Padding(padding: const EdgeInsets.only(bottom: Space.s12),

    child: TextField(controller: c, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: label)));

  void confirm({bool full = false, bool added = false}) {

    final p = widget.settings.fuelProfile;

    final ok = widget.safety?.refuel(full: full, addedL: added ? n(amount) : null,

      currentL: !full && !added && p.litresMode ? n(amount) : null,

      currentKm: !full && !added && !p.litresMode ? n(amount) : null) ?? false;

    if (ok) { Navigator.pop(context); } else { setState(() => error = 'Check the amount. Adding litres needs a known estimate without tracking gaps; otherwise set the current estimate or confirm a full tank.'); }

  }

  @override

  Widget build(BuildContext context) {

    final p = widget.settings.fuelProfile;

    final safety = widget.safety;

    final estimate = safety?.estimatedUsableKm;

    return ListView(shrinkWrap: true, children: [

      Text('Estimates only. Fuel use varies with riding conditions. Reserve and buffer are already excluded.', style: AppText.body),

      const SizedBox(height: Space.s12),

      if (safety?.fuelSaveFailed == true) Text('Fuel estimate could not be saved on this device. Keep the app open and try again.', style: AppText.label),

      if (error != null) Text(error!, style: AppText.label.copyWith(color: StatusColors.warning)),

      SwitchListTile(key: const ValueKey('shareFuelEstimate'), contentPadding: EdgeInsets.zero,

        title: const Text('Share estimated range with this device’s ride group'),

        subtitle: const Text('Off by default. Shares usable kilometres only, never litres or mileage. Offline copies expire within two minutes.'),

        value: widget.settings.shareFuelEstimate,

        onChanged: saving ? null : (value) async {

          setState(() { saving = true; error = null; });

          try { await widget.settings.setShareFuelEstimate(value); }

          catch (_) { if (mounted) setState(() => error = 'Could not save sharing preference.'); }

          finally { if (mounted) setState(() => saving = false); }

        }),

      if (editing) ...[

        SwitchListTile(key: const ValueKey('fuelLitresMode'), contentPadding: EdgeInsets.zero, title: const Text('Use litres and mileage'), value: litres,

          onChanged: (v) => setState(() { litres = v; reserve.text = '0'; })),

        if (litres) ...[field('Tank capacity (L)', capacity), field('Expected mileage (km/L)', mileage)] else field('Full tank range (km)', range),

        field(litres ? 'Reserve (L)' : 'Reserve (km)', reserve), field('Additional buffer (km)', buffer),

        FilledButton(onPressed: saving ? null : () async {

          final next = FuelProfile(capacityL: litres ? n(capacity) : 0, mileageKmL: litres ? n(mileage) : 0,

            fullRangeKm: litres ? 0 : n(range), reserveL: litres ? n(reserve) : 0, reserveKm: litres ? 0 : n(reserve), bufferKm: n(buffer));

          if (!next.valid) { setState(() => error = 'Enter valid positive values. Reserve plus buffer must leave usable range.'); return; }

          setState(() { saving = true; error = null; });

          try {

            await widget.settings.setFuelProfile(next);

            if (!context.mounted) return;

            if (widget.configure) { Navigator.pop(context); } else { setState(() { editing = false; saving = false; }); }

          } catch (_) { if (mounted) setState(() { saving = false; error = 'Could not save. Please try again.'; }); }

        }, child: const Text('Save fuel profile')),

      ] else ...[

        Text(estimate == null ? 'Current fuel estimate not set' : 'Estimated usable range: ${estimate.floor()} km', style: AppText.title),

        if (safety?.fuelEstimateUncertain == true) Text('Tracking gaps: update your estimate before relying on it.', style: AppText.label),

        if (safety != null) ...[

          const SizedBox(height: Space.s12),

          FilledButton(onPressed: () => confirm(full: true), child: const Text('Confirm filled tank')),

          const SizedBox(height: Space.s12),

          field(p.litresMode ? 'Litres' : 'Current estimated range before reserve (km)', amount),

          if (p.litresMode) OutlinedButton(onPressed: () => confirm(added: true), child: const Text('Added this many litres')),

          OutlinedButton(onPressed: () => confirm(), child: const Text('Set current estimate')),

        ],

        TextButton(onPressed: () => setState(() { editing = true; error = null; }), child: const Text('Edit fuel profile')),

      ],

    ]);

  }

}

