import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../domain/safety/fuel_profile.dart';
import '../../data/services/settings_service.dart';
import '../../data/services/safety_service.dart';

bool _isFuelSheetShowing = false;

Future<void> showFuelSheet(BuildContext context, {bool configure = false}) async {
  if (_isFuelSheetShowing) return;
  _isFuelSheetShowing = true;
  try {
    await showAppSheet<void>(
      context,
      title: 'Fuel',
      isScrollControlled: true,
      builder: (_) => _FuelSheet(
        settings: context.read<SettingsService>(),
        safety: context.read<SafetyService?>(),
        configure: configure,
      ),
    );
  } finally {
    _isFuelSheetShowing = false;
  }
}

class _FuelSheet extends StatefulWidget {
  final SettingsService settings;
  final SafetyService? safety;
  final bool configure;
  const _FuelSheet({
    required this.settings,
    required this.safety,
    required this.configure,
  });
  @override
  State<_FuelSheet> createState() => _FuelSheetState();
}

class _FuelSheetState extends State<_FuelSheet> {
  late bool editing, litres;
  late final TextEditingController capacity, mileage, range, margin;
  final amount = TextEditingController();
  String action = 'left';
  String? error;
  bool saving = false;

  String number(double n) =>
      n == n.roundToDouble() ? n.toInt().toString() : n.toStringAsFixed(1);
  @override
  void initState() {
    super.initState();
    final p = widget.settings.fuelProfile;
    editing = widget.configure || !p.valid;
    litres = p.litresMode;
    capacity = TextEditingController(
      text: p.capacityL > 0 ? number(p.capacityL) : '',
    );
    mileage = TextEditingController(
      text: p.mileageKmL > 0 ? number(p.mileageKmL) : '',
    );
    range = TextEditingController(text: p.rangeKm > 0 ? number(p.rangeKm) : '');
    margin = TextEditingController(text: number(p.marginKm));
  }

  @override
  void dispose() {
    for (final c in [capacity, mileage, range, margin, amount]) {
      c.dispose();
    }
    super.dispose();
  }

  double n(TextEditingController c) =>
      double.tryParse(c.text.trim().replaceAll(',', '.')) ?? double.nan;
  Widget field(
    String label,
    TextEditingController c, {
    String? help,
    String? hint,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: Space.s12),
    child: TextField(
      controller: c,
      enabled: !saving,
      style: AppText.body,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        helperText: help,
        helperMaxLines: 3,
        hintText: hint,
      ),
    ),
  );

  Future<void> saveSetup() async {
    final distance = litres ? n(capacity) * n(mileage) : n(range);
    final early = n(margin);
    if (!distance.isFinite || distance <= 0 || (!litres && distance > 3000)) {
      setState(
        () => error = litres
            ? 'Enter your tank size and mileage.'
            : 'Enter a full-tank distance between 1 and 3000 km.',
      );
      return;
    }
    if (!early.isFinite || early < 0 || early >= distance) {
      setState(
        () => error =
            'The safety margin must be smaller than your full-tank distance.',
      );
      return;
    }
    final buffer = early.clamp(0, 500).toDouble();
    final extra = early - buffer;
    final next = FuelProfile(
      capacityL: litres ? n(capacity) : 0,
      mileageKmL: litres ? n(mileage) : 0,
      fullRangeKm: litres ? 0 : distance,
      reserveL: litres ? extra / n(mileage) : 0,
      reserveKm: litres ? 0 : extra,
      bufferKm: buffer,
    );
    if (!next.valid) {
      setState(
        () => error =
            'Check tank size (up to 100 L) and mileage (up to 150 km/L).',
      );
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.settings.setFuelProfile(next);
      if (mounted) {
        setState(() {
          editing = false;
          amount.clear();
          action = 'left';
        });
      }
    } catch (_) {
      if (mounted) setState(() => error = 'Could not save. Please try again.');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> confirm({bool full = false}) async {
    final safety = widget.safety;
    if (safety?.fuelTrackingActive != true) return;
    final p = widget.settings.fuelProfile;
    final value = n(amount);
    final added = action == 'added';
    if (!full &&
        (!value.isFinite ||
            value < 0 ||
            (added && value == 0) ||
            value > (p.litresMode ? p.capacityL : p.rangeKm))) {
      setState(
        () => error =
            'Enter ${added ? 'more than 0 and ' : ''}up to ${number(p.litresMode ? p.capacityL : p.rangeKm)} ${p.litresMode ? 'litres' : 'km'}.',
      );
      return;
    }
    final ok = safety!.refuel(
      full: full,
      addedL: !full && added ? value : null,
      currentL: !full && !added && p.litresMode ? value : null,
      currentKm: !full && !added && !p.litresMode ? value : null,
    );
    if (ok) {
      setState(() { saving = true; error = null; });
      final saved = await safety.waitForFuelSave();
      if (!mounted) return;
      if (saved) { if (context.mounted) Navigator.pop(context); }
      else { setState(() { saving = false; error = 'Fuel updated, but could not be saved. Try again before closing.'; }); }
    } else {
      setState(
        () => error = 'The previous estimate is missing or out of date. Choose Fuel left instead.',
      );
    }
  }

  /// Amber card with the current problem, in the canvas warning colours.
  Widget _warning(String text, {String? semanticsLabel}) => Padding(
    padding: const EdgeInsets.only(bottom: Space.s12),
    child: DsCard(
      warning: true,
      tinted: false,
      color: AppTheme.warnTint,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 20, color: AppTheme.warnText),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              semanticsLabel: semanticsLabel,
              style: AppText.body.copyWith(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.warnText),
            ),
          ),
        ],
      ),
    ),
  );

  /// "YOUR USABLE RANGE" hero: the estimate, what is kept aside, a progress
  /// track and one status line (teal when the estimate is trusted, amber
  /// when riding distance was missed).
  Widget _rangeCard(FuelProfile p, double estimate, bool uncertain) {
    final usable = (p.rangeKm - p.marginKm).clamp(1.0, double.infinity);
    final fraction = (estimate / usable).clamp(0.0, 1.0);
    final statusColor = uncertain ? AppTheme.warnText : AppTheme.accentText;
    return DsCard(
      radius: Radii.xl,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('YOUR USABLE RANGE', style: AppText.overline),
                    const SizedBox(height: 2),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text.rich(
                        TextSpan(
                          text: '${estimate.floor()} ',
                          style: TextStyle(
                            color: AppTheme.accentText,
                            fontSize: 44,
                            fontWeight: FontWeight.w800,
                            height: 1,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                          children: [
                            TextSpan(
                              text: 'km',
                              style: TextStyle(color: AppTheme.muted, fontSize: 18, fontWeight: FontWeight.w800),
                            ),
                          ],
                        ),
                        maxLines: 1,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Space.s12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('Kept aside', style: AppText.caption.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text('${number(p.marginKm)} km', style: AppText.title.copyWith(fontSize: 18)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          DsProgressBar(value: fraction, color: uncertain ? AppTheme.warnText : null),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(uncertain ? Icons.warning_amber_rounded : Icons.check_rounded, size: 18, color: statusColor),
              const SizedBox(width: Space.s8),
              Expanded(
                child: Text(
                  uncertain
                      ? 'Some riding distance was missed. Enter the fuel left to start again.'
                      : 'An estimate, not a fuel gauge. ${number(p.marginKm)} km is already kept aside.',
                  style: TextStyle(color: statusColor, fontSize: 14, fontWeight: FontWeight.w700, height: 1.3),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      widget.settings,
      if (widget.safety != null) widget.safety!,
    ]),
    builder: (context, _) {
      final p = widget.settings.fuelProfile;
      final safety = widget.safety;
      final estimate = safety?.estimatedUsableKm;
      final active = safety?.fuelTrackingActive == true;
      final uncertain = safety?.fuelEstimateUncertain == true;
      final showRange = !editing && active && estimate != null;
      return ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: Space.s16),
            child: Text('Range and stops on your route', style: AppText.label),
          ),
          if (error != null) _warning(error!),
          if (editing) ...[
            Text('How far does a full tank take you?', style: AppText.title),
            const SizedBox(height: Space.s4),
            Text('Use your usual distance. You can change it later.', style: AppText.body.copyWith(color: AppTheme.text2)),
            const SizedBox(height: Space.s16),
            if (!litres)
              field('Full tank distance (km)', range, hint: 'For example, 300'),
            SwitchListTile(
              key: const ValueKey('fuelLitresMode'),
              contentPadding: EdgeInsets.zero,
              title: Text('Use tank size and mileage instead', style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
              value: litres,
              onChanged: saving
                  ? null
                  : (v) => setState(() {
                      litres = v;
                      error = null;
                    }),
            ),
            if (litres) ...[
              field('Tank size (litres)', capacity, hint: 'For example, 12'),
              field('Mileage (km per litre)', mileage, hint: 'For example, 30'),
            ],
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              shape: const Border(),
              collapsedShape: const Border(),
              iconColor: AppTheme.accentText,
              collapsedIconColor: AppTheme.muted,
              title: Text('Safety margin', style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
              subtitle: Text('${margin.text} km kept aside', style: AppText.label),
              children: [
                field(
                  'Keep aside (km)',
                  margin,
                  help: 'We subtract this once from your estimate, so you can plan an earlier stop.',
                ),
              ],
            ),
            const SizedBox(height: Space.s12),
            DsButton(
              label: saving ? 'Saving...' : 'Save and continue',
              onPressed: saving ? null : saveSetup,
            ),
            if (p.valid)
              TextButton(
                onPressed: saving
                    ? null
                    : () => setState(() {
                        editing = false;
                        error = null;
                      }),
                child: const Text('Cancel'),
              ),
          ] else ...[
            Text(
              !active
                  ? 'Fuel setup saved'
                  : uncertain
                  ? 'Update your fuel estimate'
                  : estimate == null
                  ? 'How much fuel is left?'
                  : 'About ${estimate.floor()} km before refuelling',
              style: AppText.title,
            ),
            const SizedBox(height: Space.s8),
            if (showRange)
              _rangeCard(p, estimate, uncertain)
            else
              Text(
                !active
                    ? 'Start a ride to track fuel. Then tell us if the tank is full or partly filled.'
                    : uncertain
                    ? 'Some riding distance was missed. Enter the fuel left to start again.'
                    : 'An estimate, not a fuel gauge. ${number(p.marginKm)} km is already kept aside.',
                style: AppText.body.copyWith(color: AppTheme.text2),
              ),
            const SizedBox(height: Space.s16),
            if (active) ...[
              DsButton(
                icon: Icons.local_gas_station_rounded,
                label: 'I filled the tank completely',
                onPressed: saving ? null : () => confirm(full: true),
              ),
              const SizedBox(height: Space.s16),
              if (p.litresMode)
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.s12),
                  child: Wrap(
                    spacing: Space.s8,
                    children: [
                      ChoiceChip(
                        label: const Text('Fuel left'),
                        selected: action == 'left',
                        onSelected: (_) => setState(() {
                          action = 'left';
                          amount.clear();
                          error = null;
                        }),
                      ),
                      ChoiceChip(
                        label: const Text('Fuel added'),
                        selected: action == 'added',
                        onSelected: estimate == null || uncertain
                            ? null
                            : (_) => setState(() {
                                action = 'added';
                                amount.clear();
                                error = null;
                              }),
                      ),
                    ],
                  ),
                ),
              field(
                p.litresMode
                    ? (action == 'added'
                          ? 'Litres added at the pump'
                          : 'Litres left in the tank')
                    : 'Distance left on your bike (km)',
                amount,
                help: p.litresMode
                    ? null
                    : 'Enter the bike display or your own estimate. We will keep ${number(p.marginKm)} km aside.',
              ),
              DsButton(
                tone: DsButtonTone.outline,
                label: action == 'added' ? 'Add this fuel' : 'Update fuel left',
                onPressed: saving ? null : () => confirm(),
              ),
            ],
            TextButton(
              onPressed: saving ? null : () => setState(() {
                editing = true;
                error = null;
              }),
              child: const Text('Change fuel setup'),
            ),
            if (!active)
              DsButton(
                label: 'Done',
                onPressed: () => Navigator.pop(context),
              ),
          ],
          const SizedBox(height: Space.s16),
          DsCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SwitchListTile(
              key: const ValueKey('shareFuelEstimate'),
              contentPadding: EdgeInsets.zero,
              title: Text('Share range with my group', style: AppText.body.copyWith(fontSize: 16, fontWeight: FontWeight.w700)),
              subtitle: Text(
                'Optional. Shares kilometres left, not tank size or mileage.',
                style: AppText.caption,
              ),
              value: widget.settings.shareFuelEstimate,
              onChanged: saving
                  ? null
                  : (value) async {
                      setState(() {
                        saving = true;
                        error = null;
                      });
                      try {
                        await widget.settings.setShareFuelEstimate(value);
                      } catch (_) {
                        if (mounted) {
                          setState(
                            () => error = 'Could not save sharing. Try again.',
                          );
                        }
                      } finally {
                        if (mounted) setState(() => saving = false);
                      }
                    },
            ),
          ),
          if (safety?.fuelSaveFailed == true)
            Padding(
              padding: const EdgeInsets.only(top: Space.s12),
              child: _warning(
                'This estimate has not been saved. Keep the app open and update fuel again.',
              ),
            ),
        ],
      );
    },
  );
}
