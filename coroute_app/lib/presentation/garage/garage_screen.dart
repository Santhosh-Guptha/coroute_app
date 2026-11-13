import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/garage_service.dart';
import '../../domain/garage/bike_details.dart';
import '../../domain/garage/bike_input.dart';
import '../../domain/garage/bike_profile.dart';
import '../../domain/garage/bike_type.dart';
import '../../domain/places/fuel_match.dart';
import 'bike_silhouette.dart';
import 'complete_bike_sheet.dart' show BikeTypePicker;

/// Screen managing multiple motorcycles, service reminders, and active ride bike.
class GarageScreen extends StatefulWidget {
  final GarageService? garageService;

  const GarageScreen({
    super.key,
    this.garageService,
  });

  @override
  State<GarageScreen> createState() => _GarageScreenState();
}

class _GarageScreenState extends State<GarageScreen> {
  late final GarageService _garageService;

  @override
  void initState() {
    super.initState();
    // 3.55: the app's one garage (engine care and fuel read the same active bike).
    _garageService = widget.garageService ?? GarageService.shared;
    _garageService.load();
  }

  void _showAddBikeModal() => _showBikeSheet();

  /// The add sheet; with [editing], the same sheet pre-filled, saved under the same id
  /// (odometer, service history and notes are kept).
  void _showBikeSheet({BikeProfile? editing}) {
    showModalBottomSheet(
      context: context,
      sheetAnimationStyle: AppMotion.sheetStyleOf(context), // round 7: spring in, reduce-motion aware
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 600),
      backgroundColor: AppTheme.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => _AddBikeSheet(
        initial: editing,
        onSave: (newBike) async {
          final saved = await _garageService.saveBike(newBike);
          if (!sheetContext.mounted) return;
          if (saved) {
            Navigator.of(sheetContext).maybePop();
          } else {
            ScaffoldMessenger.maybeOf(sheetContext)?.showSnackBar(
              const SnackBar(content: Text('Could not save this bike. Try again.')),
            );
          }
        },
      ),
    );
  }

  void _showRecordServiceDialog(BikeProfile bike) {
    final controller = TextEditingController(
      text: bike.totalOdometerKm.round().toString(),
    );
    showAppDialog(
      context, // round 7: app motion (spring scale + fade, reduce-motion aware)
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Record service: ${bike.name}',
          style: TextStyle(color: AppTheme.text, fontSize: 18),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Odometer reading at the service',
              style: TextStyle(color: AppTheme.text2, fontSize: 13),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              style: TextStyle(color: AppTheme.text, fontSize: 18),
              decoration: InputDecoration(
                suffixText: 'km',
                suffixStyle: TextStyle(color: AppTheme.muted),
                filled: true,
                fillColor: AppTheme.soft,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: AppTheme.border),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).maybePop();
              controller.dispose();
            },
            child: Text('Cancel', style: TextStyle(color: AppTheme.muted)),
          ),
          ElevatedButton(
            onPressed: () async {
              final val = double.tryParse(controller.text.trim());
              if (val != null && val >= 0) {
                await _garageService.recordServiceCompleted(bike.id, val);
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).maybePop();
                  controller.dispose();
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.brand,
              foregroundColor: Colors.white,
            ),
            child: const Text('Save service'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.card,
        elevation: 0,
        title: Text(
          'Garage',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: AppTheme.text,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.add_circle, color: AppTheme.accentText, size: 26),
            tooltip: 'Add bike',
            onPressed: _showAddBikeModal,
          ),
        ],
      ),
      body: ValueListenableBuilder<List<BikeProfile>>(
        valueListenable: _garageService.bikesNotifier,
        builder: (context, bikes, _) {
          return ValueListenableBuilder<BikeProfile?>(
            valueListenable: _garageService.activeBikeNotifier,
            builder: (context, activeBike, _) {
              if (bikes.isEmpty) {
                // Same empty state as the rest of the app, with a 56 dp action
                // instead of pointing at the small + in the app bar.
                return EmptyState(
                  icon: Icons.two_wheeler_rounded,
                  title: 'No bikes in your garage yet',
                  message: 'Add your bike to track service and fuel range.',
                  primaryLabel: 'Add bike',
                  onPrimary: _showAddBikeModal,
                );
              }

              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: ListView.separated(
                    // Keep the last card's buttons above the system nav bar.
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom),
                    itemCount: bikes.length,
                    separatorBuilder: (ctx, idx) => const SizedBox(height: 16),
                    itemBuilder: (context, index) {
                      final bike = bikes[index];
                      final isActive = bike.id == activeBike?.id;

                      return _BikeCard(
                        bike: bike,
                        isActive: isActive,
                        onSelectActive: () => _garageService.setActiveBike(bike.id),
                        onRecordService: () => _showRecordServiceDialog(bike),
                        onEdit: () => _showBikeSheet(editing: bike),
                        onFuelType: (t) => _garageService.saveBike(bike.copyWith(fuelType: t)),
                        // Confirm first: one stray gloved tap used to delete a bike.
                        onDelete: bikes.length > 1
                            ? () async {
                                final ok = await confirmAction(
                                  context,
                                  title: 'Remove ${bike.name}?',
                                  message: 'Its service history and fuel settings will be removed.',
                                  confirmLabel: 'Remove',
                                  destructive: true,
                                );
                                if (ok) await _garageService.deleteBike(bike.id);
                              }
                            : null,
                      );
                    },
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _BikeCard extends StatelessWidget {
  final BikeProfile bike;
  final bool isActive;
  final VoidCallback onSelectActive;
  final VoidCallback onRecordService;
  final VoidCallback? onDelete;
  final ValueChanged<BikeFuelType>? onFuelType;
  final VoidCallback? onEdit;

  const _BikeCard({
    required this.bike,
    required this.isActive,
    required this.onSelectActive,
    required this.onRecordService,
    this.onDelete,
    this.onFuelType,
    this.onEdit,
  });

  /// "452 cc · Liquid-cooled · Black" (3.55); what is not given is left out.
  static String detailsLine(BikeProfile bike) {
    final parts = <String>[
      if (bike.engineCc > 0) '${bike.engineCc} cc',
      if (bike.fuelType != BikeFuelType.ev && bike.cooling != EngineCooling.unknown) bike.cooling.label,
      if (bike.colour.trim().isNotEmpty) bike.colour.trim(),
    ];
    // 3.55 mandatory details: say what is still missing (needed before riding as a rider).
    final missing = BikeDetails.missing(bike);
    if (missing.isNotEmpty) return BikeDetails.missingLine(missing);
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    Color serviceColor = AppTheme.accentText;
    String serviceLabel = 'Service OK';
    if (bike.isServiceOverdue) {
      serviceColor = AppTheme.sos;
      serviceLabel = 'Service overdue';
    } else if (bike.isServiceDueSoon) {
      serviceColor = AppTheme.warnText;
      serviceLabel = 'Service in ${bike.kmUntilService.round()} km';
    }

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isActive ? AppTheme.accentText : AppTheme.border,
          width: 2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header Bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Row(
              children: [
                // 3.55: the bike's shape for its type, in its colour (the same shape the ride map shows).
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppTheme.soft,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: BikeSilhouette(
                    type: bike.effectiveBikeType,
                    colour: bikeColourOf(bike.colour),
                    width: 56,
                    semanticLabel: '${bike.effectiveBikeType.label}${bike.colour.trim().isEmpty ? '' : ', ${bike.colour.trim()}'}',
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        bike.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppTheme.text,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      // No year field in the add/edit sheet, so the stored default year is not shown.
                      Text(
                        '${bike.make} ${bike.model}'.trim().isEmpty ? 'Make and model not set' : '${bike.make} ${bike.model}'.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppTheme.text2,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isActive)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: AppTheme.tint,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.accentText.withValues(alpha: 0.5)),
                    ),
                    child: Text(
                      'ACTIVE',
                      style: TextStyle(
                        color: AppTheme.accentText,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.0,
                      ),
                    ),
                  )
                else
                  TextButton(
                    onPressed: onSelectActive,
                    style: TextButton.styleFrom(
                      foregroundColor: AppTheme.accentText,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      minimumSize: const Size(48, 48),
                    ),
                    child: const Text('Set active'),
                  ),
              ],
            ),
          ),

          // 3.55 bike details and full-tank range, with "Edit details".
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
            child: Row(
              children: [
                Icon(Icons.settings_suggest_rounded, size: 18, color: AppTheme.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        detailsLine(bike),
                        key: ValueKey('bikeDetails_${bike.id}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: AppTheme.text, fontSize: 13, fontWeight: FontWeight.w700),
                      ),
                      Text(
                        'Full tank ≈ ${bike.fullTankRangeKm.round()} km',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: AppTheme.text2, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (onEdit != null)
                  TextButton.icon(
                    key: ValueKey('editBike_${bike.id}'),
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_rounded, size: 18),
                    label: const Text('Edit details'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppTheme.accentText,
                      minimumSize: const Size(48, 48),
                    ),
                  ),
              ],
            ),
          ),

          Divider(height: 1, color: AppTheme.border),

          // Fuel type: stations on the map and fuel warnings match it.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Icon(bike.fuelType == BikeFuelType.ev ? Icons.ev_station_rounded : Icons.local_gas_station_rounded,
                    size: 18, color: AppTheme.muted),
                const SizedBox(width: 8),
                Expanded(child: Text('Runs on', style: TextStyle(color: AppTheme.muted, fontSize: 12, fontWeight: FontWeight.w700))),
                PopupMenuButton<BikeFuelType>(
                  key: ValueKey('fuelType_${bike.id}'),
                  tooltip: 'Fuel type',
                  initialValue: bike.fuelType,
                  enabled: onFuelType != null,
                  onSelected: (t) => onFuelType?.call(t),
                  itemBuilder: (_) => [
                    for (final t in BikeFuelType.values) PopupMenuItem(value: t, child: Text(t.label)),
                  ],
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 48),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    alignment: Alignment.center,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(bike.fuelType.label, style: TextStyle(color: AppTheme.text, fontWeight: FontWeight.w600)),
                      Icon(Icons.arrow_drop_down_rounded, color: AppTheme.muted),
                    ]),
                  ),
                ),
              ],
            ),
          ),

          // Specs Grid
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: _MiniSpec(
                    label: 'TANK CAPACITY',
                    value: '${bike.tankCapacityL.toStringAsFixed(1)} ${bike.fuelType.unit}',
                    subtext: '${bike.fullTankRangeKm.round()} km max',
                  ),
                ),
                Expanded(
                  child: _MiniSpec(
                    label: 'CONSUMPTION',
                    value: '${bike.expectedMileageKmL.round()} km/${bike.fuelType.unit}',
                    subtext: '${bike.reserveRangeKm.round()} km reserve',
                  ),
                ),
                Expanded(
                  child: _MiniSpec(
                    label: 'ODOMETER',
                    value: '${bike.totalOdometerKm.round()} km',
                    subtext: 'Recorded',
                  ),
                ),
              ],
            ),
          ),

          // Maintenance Status Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.soft,
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: serviceColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    serviceLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: serviceColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: onRecordService,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 48),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    alignment: Alignment.center,
                    child: Text(
                      'Record service',
                      style: TextStyle(
                        color: AppTheme.text2,
                        fontSize: 12,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ),
                if (onDelete != null) ...[
                  const SizedBox(width: 6),
                  Semantics(
                    button: true,
                    label: 'Remove ${bike.name}',
                    child: InkWell(
                      onTap: onDelete,
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
                        alignment: Alignment.center,
                        child: Icon(Icons.delete_outline, color: AppTheme.muted, size: 22),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniSpec extends StatelessWidget {
  final String label;
  final String value;
  final String subtext;

  const _MiniSpec({
    required this.label,
    required this.value,
    required this.subtext,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: AppTheme.muted,
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 1,
            style: TextStyle(
              color: AppTheme.text,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
            ),
          ),
        ),
        Text(
          subtext,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: AppTheme.text2,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

class _AddBikeSheet extends StatefulWidget {
  final ValueChanged<BikeProfile> onSave;

  /// The bike being edited (3.55); null adds a new one.
  final BikeProfile? initial;

  const _AddBikeSheet({required this.onSave, this.initial});

  @override
  State<_AddBikeSheet> createState() => _AddBikeSheetState();
}

/// Quick colour chips (3.55): the name is what the group sees; the swatch only helps pick.
const List<(String, Color)> _quickColours = [
  ('Black', Color(0xFF111111)),
  ('White', Color(0xFFF5F5F5)),
  ('Red', Color(0xFFD32F2F)),
  ('Blue', Color(0xFF1E63D6)),
  ('Grey', Color(0xFF7A7A7A)),
  ('Silver', Color(0xFFC0C0C0)),
  ('Green', Color(0xFF2E7D32)),
  ('Yellow', Color(0xFFF9C80E)),
  ('Orange', Color(0xFFF57C00)),
];

class _AddBikeSheetState extends State<_AddBikeSheet> {
  final _nameController = TextEditingController();
  final _makeController = TextEditingController();
  final _modelController = TextEditingController();
  final _ccController = TextEditingController();
  final _colourController = TextEditingController();
  final _tankController = TextEditingController(text: '15.0');
  final _reserveController = TextEditingController(text: '3.0');
  final _mileageController = TextEditingController(text: '25.0');
  final _odometerController = TextEditingController(text: '0');
  BikeFuelType _fuelType = BikeFuelType.petrol;
  EngineCooling _cooling = EngineCooling.unknown;

  /// 3.55 bike type (shape on the map): picked, or pre-selected from the model for the rider to confirm.
  BikeType? _type;

  /// Field → friendly message, shown under each field when "Save to garage" finds a problem
  /// (the button used to do nothing, with no feedback).
  Map<String, String> _errors = const {};

  bool get _editing => widget.initial != null;

  @override
  void initState() {
    super.initState();
    final b = widget.initial;
    if (b != null) {
      _nameController.text = b.name;
      _makeController.text = b.make;
      _modelController.text = b.model;
      _ccController.text = b.engineCc > 0 ? '${b.engineCc}' : '';
      _colourController.text = b.colour;
      _tankController.text = _num(b.tankCapacityL);
      _reserveController.text = _num(b.reserveCapacityL);
      _mileageController.text = _num(b.expectedMileageKmL);
      _odometerController.text = b.totalOdometerKm.round().toString();
      _fuelType = b.fuelType;
      _cooling = b.cooling;
      _type = b.bikeType ?? BikeDetailsSuggest.typeFor(b);
    }
  }

  /// Typing the model pre-selects the type and fills empty details a preset knows.
  void _onModelTyped() {
    final p = BikeDetailsSuggest.presetFor(_makeController.text, _modelController.text);
    setState(() {
      _errors = {..._errors}..remove('model');
      if (p != null && _ccController.text.trim().isEmpty && p.engineCc > 0) _ccController.text = '${p.engineCc}';
      if (widget.initial?.bikeType == null) {
        _type = p?.bikeType ??
            BikeTypeInference.infer(make: _makeController.text, model: _modelController.text, name: _nameController.text, fuelType: _fuelType) ??
            _type;
      }
    });
  }

  static String _num(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  @override
  void dispose() {
    _nameController.dispose();
    _makeController.dispose();
    _modelController.dispose();
    _ccController.dispose();
    _colourController.dispose();
    _tankController.dispose();
    _reserveController.dispose();
    _mileageController.dispose();
    _odometerController.dispose();
    super.dispose();
  }

  void _applyPreset(BikeProfile p) {
    setState(() {
      _nameController.text = p.name;
      _makeController.text = p.make;
      _modelController.text = p.model;
      _tankController.text = p.tankCapacityL.toString();
      _reserveController.text = p.reserveCapacityL.toString();
      _mileageController.text = p.expectedMileageKmL.toString();
      // 3.55: presets also know the engine size and cooling.
      _ccController.text = p.engineCc > 0 ? '${p.engineCc}' : '';
      _cooling = p.cooling;
      _fuelType = p.fuelType;
      _type = p.bikeType ?? _type;
      _errors = const {};
    });
  }

  void _clearError(String field) {
    if (_errors.containsKey(field)) setState(() => _errors = {..._errors}..remove(field));
  }

  void _save() {
    // 3.55 mandatory details: make / model, type, colour, engine size (not electric), tank, mileage.
    final errors = validateBikeDetails(
      name: _nameController.text,
      make: _makeController.text,
      model: _modelController.text,
      type: _type,
      colour: _colourController.text,
      cc: _ccController.text,
      tank: _tankController.text,
      reserve: _reserveController.text,
      mileage: _mileageController.text,
      odometer: _odometerController.text,
      fuelType: _fuelType,
    );
    if (errors.isNotEmpty) {
      setState(() => _errors = errors);
      return;
    }
    final cc = parseBikeNumber(_ccController.text)?.round() ?? 0;
    final tank = parseBikeNumber(_tankController.text) ?? 0.0; // empty only for an electric bike's battery
    final reserve = (parseBikeNumber(_reserveController.text) ?? 0.0).clamp(0.0, tank > 0 ? tank * 0.9 : 0.0).toDouble();
    final mileage = parseBikeNumber(_mileageController.text)!;
    final colour = _colourController.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    final initial = widget.initial;
    final odo = parseBikeNumber(_odometerController.text) ?? initial?.totalOdometerKm ?? 0.0;
    final evBike = _fuelType == BikeFuelType.ev;

    final base = initial ?? BikeProfile(id: 'bike_${DateTime.now().millisecondsSinceEpoch}', name: '');
    // copyWith keeps the id, service interval, last service, notes and year of an edited bike.
    final bike = base.copyWith(
      name: _nameController.text.trim().isEmpty ? '${_makeController.text.trim()} ${_modelController.text.trim()}'.trim() : _nameController.text.trim(),
      make: _makeController.text.trim(),
      model: _modelController.text.trim(),
      tankCapacityL: tank,
      reserveCapacityL: reserve,
      expectedMileageKmL: mileage,
      totalOdometerKm: odo,
      fuelType: _fuelType,
      engineCc: evBike ? initial?.engineCc ?? 0 : cc,
      colour: colour.length > 30 ? colour.substring(0, 30).trim() : colour,
      cooling: evBike ? initial?.cooling ?? EngineCooling.unknown : _cooling,
      bikeType: _type,
    );
    widget.onSave(bike);
  }

  InputDecoration _decoration(String label, String field, {String? helper}) => InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: AppTheme.muted),
        errorText: _errors[field],
        errorMaxLines: 2,
        helperText: helper,
        helperMaxLines: 2,
      );

  Widget _sectionLabel(String text) => Text(
        text,
        style: TextStyle(color: AppTheme.muted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8),
      );

  @override
  Widget build(BuildContext context) {
    final presets = BikeProfile.popularPresets;
    final evBike = _fuelType == BikeFuelType.ev;
    final typedCc = parseBikeNumber(_ccController.text)?.round() ?? 0;
    final guess = BikeProfile(id: '', name: '', engineCc: typedCc).effectiveCooling;
    final colourNow = _colourController.text.trim().toLowerCase();

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Padding(
          padding: EdgeInsets.only(
            top: 20,
            left: 20,
            right: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + MediaQuery.paddingOf(context).bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        _editing ? 'Edit bike' : 'Add bike',
                        style: TextStyle(
                          color: AppTheme.text,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      icon: Icon(Icons.close, color: AppTheme.muted),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _sectionLabel('QUICK PRESETS'),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: presets.map((p) {
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ActionChip(
                          backgroundColor: AppTheme.soft,
                          label: Text(
                            p.model,
                            style: TextStyle(color: AppTheme.text, fontSize: 12),
                          ),
                          onPressed: () => _applyPreset(p),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const ValueKey('bikeName'),
                  controller: _nameController,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  onChanged: (_) => _clearError('name'),
                  style: TextStyle(color: AppTheme.text),
                  decoration: _decoration('Bike name (optional, e.g. My Himalayan 450)', 'name'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _makeController,
                        textCapitalization: TextCapitalization.words,
                        onChanged: (_) => _onModelTyped(),
                        style: TextStyle(color: AppTheme.text),
                        decoration: _decoration('Make', 'make'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        key: const ValueKey('bikeModel'),
                        controller: _modelController,
                        textCapitalization: TextCapitalization.words,
                        onChanged: (_) => _onModelTyped(),
                        style: TextStyle(color: AppTheme.text),
                        decoration: _decoration('Model', 'model'),
                      ),
                    ),
                  ],
                ),
                // 3.55 bike type: the shape the group sees on the map (pre-selected from the model).
                const SizedBox(height: 12),
                _sectionLabel('BIKE TYPE'),
                const SizedBox(height: 6),
                BikeTypePicker(
                  selected: _type,
                  colour: bikeColourOf(_colourController.text),
                  onChanged: (t) => setState(() {
                    _type = t;
                    if (t == BikeType.electric) _fuelType = BikeFuelType.ev;
                    _errors = {..._errors}..remove('type');
                  }),
                ),
                if (_type != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(_type!.hint, style: TextStyle(color: AppTheme.text2, fontSize: 12)),
                  ),
                if (_errors['type'] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(_errors['type']!, style: TextStyle(color: AppTheme.sos, fontSize: 12)),
                  ),
                const SizedBox(height: 12),
                _sectionLabel('RUNS ON'),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final t in BikeFuelType.values)
                      ChoiceChip(
                        key: ValueKey('addBikeFuel_${t.name}'),
                        label: Text(t.label),
                        selected: _fuelType == t,
                        onSelected: (_) => setState(() => _fuelType = t),
                      ),
                  ],
                ),
                // 3.55 engine details: they set when an engine rest is advised on a long hard ride.
                if (!evBike) ...[
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('bikeCc'),
                    controller: _ccController,
                    keyboardType: TextInputType.number,
                    onChanged: (_) {
                      _clearError('cc');
                      setState(() {});
                    },
                    style: TextStyle(color: AppTheme.text),
                    decoration: _decoration('Engine (cc)', 'cc', helper: 'Required, e.g. 350').copyWith(
                      suffixText: 'cc',
                      suffixStyle: TextStyle(color: AppTheme.muted),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _sectionLabel('COOLING'),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final c in EngineCooling.values)
                        ChoiceChip(
                          key: ValueKey('bikeCooling_${c.name}'),
                          label: Text(c.label),
                          selected: _cooling == c,
                          onSelected: (_) => setState(() => _cooling = c),
                        ),
                    ],
                  ),
                  if (_cooling == EngineCooling.unknown && guess != EngineCooling.unknown)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'Not sure: we will treat a $typedCc cc engine as ${guess.label.toLowerCase()}.',
                        style: TextStyle(color: AppTheme.text2, fontSize: 12),
                      ),
                    ),
                ],
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('bikeColour'),
                  controller: _colourController,
                  textCapitalization: TextCapitalization.words,
                  maxLength: 30,
                  onChanged: (_) => setState(() => _errors = {..._errors}..remove('colour')),
                  style: TextStyle(color: AppTheme.text),
                  decoration: _decoration('Colour', 'colour', helper: 'Your group sees it on the ride map'),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final (name, swatch) in _quickColours)
                      ChoiceChip(
                        key: ValueKey('bikeColourChip_$name'),
                        avatar: Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            color: swatch,
                            shape: BoxShape.circle,
                            border: Border.all(color: AppTheme.border),
                          ),
                        ),
                        label: Text(name),
                        selected: colourNow == name.toLowerCase(),
                        onSelected: (_) => setState(() {
                          _colourController.text = name;
                          _errors = {..._errors}..remove('colour');
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('bikeTank'),
                        controller: _tankController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        onChanged: (_) => _clearError('tank'),
                        style: TextStyle(color: AppTheme.text),
                        decoration: _decoration(evBike ? 'Battery (kWh, optional)' : 'Tank (${_fuelType.unit})', 'tank'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        key: const ValueKey('bikeReserve'),
                        controller: _reserveController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        onChanged: (_) => _clearError('reserve'),
                        style: TextStyle(color: AppTheme.text),
                        decoration: _decoration('Reserve (${_fuelType.unit})', 'reserve'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        key: const ValueKey('bikeMileage'),
                        controller: _mileageController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        onChanged: (_) => _clearError('mileage'),
                        style: TextStyle(color: AppTheme.text),
                        decoration: _decoration('Mileage (km/${_fuelType.unit})', 'mileage'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('bikeOdometer'),
                  controller: _odometerController,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => _clearError('odometer'),
                  style: TextStyle(color: AppTheme.text),
                  decoration: _decoration('Current odometer (km)', 'odometer'),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    key: const ValueKey('saveBike'),
                    onPressed: _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.brand,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(
                      _editing ? 'Save changes' : 'Save to garage',
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
