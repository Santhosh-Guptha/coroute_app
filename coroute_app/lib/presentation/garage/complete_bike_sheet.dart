import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/app_theme.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/garage_binding.dart';
import '../../data/services/garage_service.dart';
import '../../domain/garage/bike_details.dart';
import '../../domain/garage/bike_input.dart';
import '../../domain/garage/bike_profile.dart';
import '../../domain/garage/bike_sync.dart';
import '../../domain/garage/bike_type.dart';
import '../../domain/places/fuel_match.dart';
import 'bike_silhouette.dart';

/// How the rider goes on after the bike check.
enum BikeGateResult { rider, pillion, cancelled }

/// 3.55 mandatory bike details before riding: creating or joining a ride as a RIDER needs an active
/// garage bike with complete details ([BikeDetails]). When something is missing, a quick
/// "Complete your bike" sheet opens inline, pre-filled (preset for the model, type guess), so it
/// takes a few taps. A pillion goes straight on. Never used for SOS, never mid-ride, and the app is
/// never locked: closing the sheet only cancels this create / join.
class BikeGate {
  BikeGate._();

  /// True when [pillionAccount] (the profile says pillion) or the bike is complete; otherwise the
  /// sheet. [allowPillion] offers "I'm riding pillion" (joining a ride).
  ///
  /// 3.56 (asked every time): decided only from the garage's active bike, after the garage has
  /// loaded and after the profile on the gateway had the chance to fill what this phone is
  /// missing (a new install / phone). The sheet saves into the garage, so the next create / join
  /// goes straight on.
  static Future<BikeGateResult> ensureReady(BuildContext context, {bool pillionAccount = false, bool allowPillion = true, GarageService? garage}) async {
    if (pillionAccount) return BikeGateResult.pillion;
    final g = garage ?? GarageService.shared;
    await g.load();
    var step = BikeGatePlan.decide(pillionAccount: false, loaded: g.isLoaded, active: g.activeBikeNotifier.value);
    if (step == BikeGateStep.ask && context.mounted) {
      final binding = _binding(context, g);
      if (binding != null) {
        await binding.restoreFromServer();
        step = BikeGatePlan.decide(pillionAccount: false, loaded: g.isLoaded, active: g.activeBikeNotifier.value);
      }
    }
    if (step == BikeGateStep.rider) return BikeGateResult.rider;
    if (!context.mounted) return BikeGateResult.cancelled;
    final r = await showCompleteBikeSheet(context, garage: g, allowPillion: allowPillion);
    return r ?? BikeGateResult.cancelled;
  }

  /// The app's garage binding (restores from the profile), when it binds this garage.
  static GarageBinding? _binding(BuildContext context, GarageService g) {
    try {
      final b = Provider.of<GarageBinding>(context, listen: false);
      return identical(b.garage, g) ? b : null;
    } catch (_) {
      return null; // no provider (tests, previews)
    }
  }

  static const String _promptedKey = 'coroute_bike_details_prompted_v1';

  /// Existing riders whose active bike misses details are asked once (never again after that,
  /// shown or dismissed; never for a pillion account; creating or joining a ride still asks until
  /// the bike is complete).
  static Future<void> promptOnce(BuildContext context, {GarageService? garage}) async {
    final g = garage ?? GarageService.shared;
    try {
      final sp = await SharedPreferences.getInstance();
      if (sp.getBool(_promptedKey) == true || !context.mounted) return;
      var pillion = false;
      try {
        pillion = Provider.of<AuthService>(context, listen: false).isPillion;
      } catch (_) {}
      if (pillion) return;
      final binding = _binding(context, g);
      await g.load();
      if (binding != null) await binding.restoreFromServer();
      if (!BikeGatePlan.shouldPromptOnce(alreadyPrompted: false, pillionAccount: pillion, loaded: g.isLoaded, active: g.activeBikeNotifier.value)) return;
      await sp.setBool(_promptedKey, true);
      if (!context.mounted) return;
      await showCompleteBikeSheet(context, garage: g, allowPillion: false, intro: 'Your group now sees your bike\'s shape and colour on the map. Check these details once.');
    } catch (e) {
      debugPrint('bike details prompt: $e');
    }
  }
}

/// Place once on a home screen: asks [BikeGate.promptOnce] after the first frame (draws nothing).
class BikeDetailsOncePrompt extends StatefulWidget {
  const BikeDetailsOncePrompt({super.key});

  @override
  State<BikeDetailsOncePrompt> createState() => _BikeDetailsOncePromptState();
}

class _BikeDetailsOncePromptState extends State<BikeDetailsOncePrompt> {
  static bool _askedThisRun = false;

  @override
  void initState() {
    super.initState();
    if (_askedThisRun) return;
    _askedThisRun = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) BikeGate.promptOnce(context);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// The "Complete your bike" sheet. Returns [BikeGateResult.rider] once a complete bike is saved
/// (and active), [BikeGateResult.pillion] when the rider chose "I'm riding pillion", null when closed.
Future<BikeGateResult?> showCompleteBikeSheet(BuildContext context, {GarageService? garage, bool allowPillion = true, String? intro}) {
  final g = garage ?? GarageService.shared;
  return showModalBottomSheet<BikeGateResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTheme.card,
    constraints: const BoxConstraints(maxWidth: 600),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (_) => _CompleteBikeSheet(garage: g, allowPillion: allowPillion, intro: intro),
  );
}

const List<(String, Color)> _colours = [
  ('Black', Color(0xFF1B1B1B)),
  ('White', Color(0xFFF4F4F4)),
  ('Red', Color(0xFFD32F2F)),
  ('Blue', Color(0xFF1E63D6)),
  ('Grey', Color(0xFF7A7A7A)),
  ('Silver', Color(0xFFC0C0C0)),
  ('Green', Color(0xFF2E7D32)),
  ('Yellow', Color(0xFFF9C80E)),
  ('Orange', Color(0xFFF57C00)),
];

class _CompleteBikeSheet extends StatefulWidget {
  const _CompleteBikeSheet({required this.garage, required this.allowPillion, this.intro});
  final GarageService garage;
  final bool allowPillion;
  final String? intro;

  @override
  State<_CompleteBikeSheet> createState() => _CompleteBikeSheetState();
}

class _CompleteBikeSheetState extends State<_CompleteBikeSheet> {
  late BikeProfile _base;
  final _model = TextEditingController();
  final _cc = TextEditingController();
  final _colour = TextEditingController();
  final _tank = TextEditingController();
  final _mileage = TextEditingController();
  BikeType? _type;
  BikeFuelType _fuel = BikeFuelType.petrol;
  Map<String, String> _errors = const {};
  bool _saving = false;

  static String _num(double v) => v <= 0 ? '' : (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString());

  @override
  void initState() {
    super.initState();
    final active = widget.garage.activeBikeNotifier.value;
    _base = BikeDetailsSuggest.fill(active ?? BikeProfile(id: 'bike_${DateTime.now().millisecondsSinceEpoch}', name: ''));
    _model.text = '${_base.make} ${_base.model}'.trim().isEmpty ? _base.name : '${_base.make} ${_base.model}'.trim();
    _cc.text = _base.engineCc > 0 ? '${_base.engineCc}' : '';
    _colour.text = _base.colour;
    _tank.text = active == null ? '' : _num(_base.tankCapacityL);
    _mileage.text = active == null ? '' : _num(_base.expectedMileageKmL);
    _fuel = _base.fuelType;
    _type = _base.bikeType ?? (_model.text.trim().isEmpty ? null : BikeDetailsSuggest.typeFor(_base));
  }

  @override
  void dispose() {
    for (final c in [_model, _cc, _colour, _tank, _mileage]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Typing a model fills what a preset knows (only empty fields) and the type guess.
  void _onModel(String v) {
    final p = BikeDetailsSuggest.presetFor('', v);
    setState(() {
      _errors = {..._errors}..remove('model');
      if (p != null) {
        if (_cc.text.trim().isEmpty && p.engineCc > 0) _cc.text = '${p.engineCc}';
        if (_tank.text.trim().isEmpty) _tank.text = _num(p.tankCapacityL);
        if (_mileage.text.trim().isEmpty) _mileage.text = _num(p.expectedMileageKmL);
        if (p.fuelType == BikeFuelType.ev) _fuel = BikeFuelType.ev;
      }
      _type ??= p?.bikeType ?? BikeTypeInference.infer(model: v, fuelType: _fuel);
    });
  }

  Future<void> _save() async {
    final ev = _fuel == BikeFuelType.ev;
    final errors = validateBikeDetails(
      name: _base.name.trim().isEmpty ? _model.text : _base.name,
      make: '',
      model: _model.text,
      type: _type,
      colour: _colour.text,
      cc: ev ? '' : _cc.text,
      tank: _tank.text,
      reserve: '0', // the reserve is not a required detail (kept, or 15 % of the tank)
      mileage: _mileage.text,
      odometer: '',
      fuelType: _fuel,
    );
    if (errors.isNotEmpty) {
      setState(() => _errors = errors);
      return;
    }
    setState(() => _saving = true);
    final typed = _model.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    // The typed text is kept as the model when the bike had no make (the group sees make + model).
    final hadMake = _base.make.trim().isNotEmpty && typed.toLowerCase().startsWith(_base.make.trim().toLowerCase());
    final tank = parseBikeNumber(_tank.text) ?? (ev ? 0.0 : _base.tankCapacityL);
    final bike = _base.copyWith(
      name: _base.name.trim().isEmpty ? typed : _base.name,
      make: hadMake ? _base.make : '',
      model: hadMake ? typed.substring(_base.make.trim().length).trim() : typed,
      bikeType: _type,
      engineCc: ev ? _base.engineCc : (parseBikeNumber(_cc.text)?.round() ?? 0),
      colour: _colour.text.trim(),
      tankCapacityL: tank,
      reserveCapacityL: _base.reserveCapacityL < tank ? _base.reserveCapacityL : tank * 0.15,
      expectedMileageKmL: parseBikeNumber(_mileage.text) ?? _base.expectedMileageKmL,
      fuelType: _fuel,
    );
    final ok = await widget.garage.saveBike(bike);
    if (ok) await widget.garage.setActiveBike(bike.id);
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok && BikeDetails.isComplete(widget.garage.activeBikeNotifier.value)) {
      Navigator.of(context).pop(BikeGateResult.rider);
    } else {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Could not save this bike. Try again.')));
    }
  }

  InputDecoration _dec(String label, String key, {String? hint, String? suffix}) => InputDecoration(
        labelText: label,
        hintText: hint,
        errorText: _errors[key],
        errorMaxLines: 2,
        suffixText: suffix,
      );

  @override
  Widget build(BuildContext context) {
    final ev = _fuel == BikeFuelType.ev;
    final colourNow = _colour.text.trim().toLowerCase();
    return Padding(
      padding: EdgeInsets.only(left: 20, right: 20, top: 20, bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                BikeSilhouette(type: _type ?? BikeType.commuter, colour: bikeColourOf(_colour.text), width: 72),
                const SizedBox(width: 12),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text('Complete your bike', style: TextStyle(color: AppTheme.text, fontSize: 18, fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(widget.intro ?? 'Riders need these before a ride: your group sees your bike, and fuel stops use the tank and mileage.',
                style: TextStyle(color: AppTheme.text2, fontSize: 13)),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('completeBikeModel'),
              controller: _model,
              textCapitalization: TextCapitalization.words,
              onChanged: _onModel,
              decoration: _dec('Make and model', 'model', hint: 'e.g. Royal Enfield Classic 350'),
            ),
            const SizedBox(height: 10),
            Text('Bike type', style: TextStyle(color: AppTheme.muted, fontSize: 12, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            BikeTypePicker(
              selected: _type,
              colour: bikeColourOf(_colour.text),
              onChanged: (t) => setState(() {
                _type = t;
                if (t == BikeType.electric) _fuel = BikeFuelType.ev;
                if (t != BikeType.electric && _fuel == BikeFuelType.ev) _fuel = BikeFuelType.petrol;
                _errors = {..._errors}..remove('type');
              }),
            ),
            if (_errors['type'] != null)
              Padding(padding: const EdgeInsets.only(top: 4), child: Text(_errors['type']!, style: TextStyle(color: AppTheme.sos, fontSize: 12))),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final (name, swatch) in _colours)
                  ChoiceChip(
                    avatar: CircleAvatar(backgroundColor: swatch, radius: 7),
                    label: Text(name),
                    selected: colourNow == name.toLowerCase(),
                    onSelected: (_) => setState(() {
                      _colour.text = name;
                      _errors = {..._errors}..remove('colour');
                    }),
                  ),
              ],
            ),
            TextField(
              key: const ValueKey('completeBikeColour'),
              controller: _colour,
              maxLength: 30,
              textCapitalization: TextCapitalization.words,
              onChanged: (_) => setState(() => _errors = {..._errors}..remove('colour')),
              decoration: _dec('Colour', 'colour', hint: 'or type it, e.g. Gunmetal Grey'),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!ev) ...[
                  Expanded(
                    child: TextField(
                      key: const ValueKey('completeBikeCc'),
                      controller: _cc,
                      keyboardType: TextInputType.number,
                      decoration: _dec('Engine', 'cc', suffix: 'cc'),
                    ),
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: TextField(
                    key: const ValueKey('completeBikeTank'),
                    controller: _tank,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: _dec(ev ? 'Battery (optional)' : 'Tank', 'tank', suffix: _fuel.unit),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    key: const ValueKey('completeBikeMileage'),
                    controller: _mileage,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: _dec('Mileage', 'mileage', suffix: 'km/${_fuel.unit}'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 52,
              child: FilledButton(
                key: const ValueKey('completeBikeSave'),
                onPressed: _saving ? null : _save,
                child: const Text('Save and continue'),
              ),
            ),
            if (widget.allowPillion)
              TextButton(
                key: const ValueKey('completeBikePillion'),
                onPressed: () => Navigator.of(context).pop(BikeGateResult.pillion),
                child: const Text("I'm riding pillion (no bike)"),
              ),
          ],
        ),
      ),
    );
  }
}

/// The bike type chooser: each type with its shape (the rider confirms the guess with one tap).
class BikeTypePicker extends StatelessWidget {
  const BikeTypePicker({super.key, required this.selected, required this.onChanged, this.colour = const Color(0xFF7A7A7A)});
  final BikeType? selected;
  final ValueChanged<BikeType> onChanged;
  final Color colour;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 78,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final t in BikeType.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Semantics(
                button: true,
                selected: selected == t,
                label: '${t.label}. ${t.hint}',
                excludeSemantics: true,
                child: InkWell(
                  key: ValueKey('bikeType_${t.name}'),
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => onChanged(t),
                  child: Container(
                    width: 84,
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: selected == t ? AppTheme.tint : AppTheme.soft,
                      border: Border.all(color: selected == t ? AppTheme.accentText : AppTheme.border, width: selected == t ? 2 : 1),
                    ),
                    child: Column(
                      children: [
                        BikeSilhouette(type: t, colour: colour, width: 52),
                        const SizedBox(height: 2),
                        Text(t.label.split(' / ').first, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: AppTheme.text, fontSize: 11, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
