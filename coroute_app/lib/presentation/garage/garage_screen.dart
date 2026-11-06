import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/garage_service.dart';
import '../../domain/garage/bike_profile.dart';
import '../../domain/places/fuel_match.dart';

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
    _garageService = widget.garageService ?? GarageService();
    _garageService.load();
  }

  void _showAddBikeModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 600),
      backgroundColor: AppTheme.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => _AddBikeSheet(
        onSave: (newBike) async {
          await _garageService.saveBike(newBike);
          if (sheetContext.mounted) {
            Navigator.of(sheetContext).maybePop();
          }
        },
      ),
    );
  }

  void _showRecordServiceDialog(BikeProfile bike) {
    final controller = TextEditingController(
      text: bike.totalOdometerKm.round().toString(),
    );
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Service Completed: ${bike.name}',
          style: TextStyle(color: AppTheme.text, fontSize: 18),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Odometer reading at service:',
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
            child: const Text('Confirm Service'),
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
          'GARAGE & MOTORCYCLES',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: AppTheme.text,
            fontSize: 16,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.add_circle, color: AppTheme.accentText, size: 26),
            tooltip: 'Add Motorcycle',
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
                  title: 'No motorcycles in your garage yet',
                  message: 'Add your bike to track service and fuel range.',
                  primaryLabel: 'Add motorcycle',
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

  const _BikeCard({
    required this.bike,
    required this.isActive,
    required this.onSelectActive,
    required this.onRecordService,
    this.onDelete,
    this.onFuelType,
  });

  @override
  Widget build(BuildContext context) {
    Color serviceColor = AppTheme.accentText;
    String serviceLabel = 'SERVICE OK';
    if (bike.isServiceOverdue) {
      serviceColor = AppTheme.sos;
      serviceLabel = 'SERVICE OVERDUE';
    } else if (bike.isServiceDueSoon) {
      serviceColor = AppTheme.warnText;
      serviceLabel = 'DUE IN ${bike.kmUntilService.round()} KM';
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
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.soft,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.two_wheeler,
                    color: isActive ? AppTheme.accentText : AppTheme.muted,
                    size: 26,
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
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        '${bike.year} · ${bike.make} ${bike.model}',
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
                        fontWeight: FontWeight.w800,
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
                    child: const Text('Set Active'),
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
                    constraints: const BoxConstraints(minHeight: 40),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    alignment: Alignment.center,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(bike.fuelType.label, style: TextStyle(color: AppTheme.text, fontWeight: FontWeight.w800)),
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
                      fontWeight: FontWeight.w800,
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
                      'Record Service',
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
              fontWeight: FontWeight.w800,
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

  const _AddBikeSheet({required this.onSave});

  @override
  State<_AddBikeSheet> createState() => _AddBikeSheetState();
}

class _AddBikeSheetState extends State<_AddBikeSheet> {
  final _nameController = TextEditingController();
  final _makeController = TextEditingController();
  final _modelController = TextEditingController();
  final _tankController = TextEditingController(text: '15.0');
  final _reserveController = TextEditingController(text: '3.0');
  final _mileageController = TextEditingController(text: '25.0');
  final _odometerController = TextEditingController(text: '0');
  BikeFuelType _fuelType = BikeFuelType.petrol;

  /// Shown under the name field when [SAVE TO GARAGE] is pressed without a name
  /// (the button used to do nothing, with no feedback).
  String? _nameError;

  @override
  void dispose() {
    _nameController.dispose();
    _makeController.dispose();
    _modelController.dispose();
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
    });
  }

  @override
  Widget build(BuildContext context) {
    final presets = BikeProfile.popularPresets;

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
                    Text(
                      'ADD MOTORCYCLE',
                      style: TextStyle(
                        color: AppTheme.text,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2,
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
            Text(
              'QUICK PRESETS',
              style: TextStyle(
                color: AppTheme.muted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.8,
              ),
            ),
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
              controller: _nameController,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              onChanged: (_) {
                if (_nameError != null) setState(() => _nameError = null);
              },
              style: TextStyle(color: AppTheme.text),
              decoration: InputDecoration(
                labelText: 'Bike Name (e.g. My Himalayan 450)',
                labelStyle: TextStyle(color: AppTheme.muted),
                errorText: _nameError,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _makeController,
                    style: TextStyle(color: AppTheme.text),
                    decoration: InputDecoration(
                      labelText: 'Make',
                      labelStyle: TextStyle(color: AppTheme.muted),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _modelController,
                    style: TextStyle(color: AppTheme.text),
                    decoration: InputDecoration(
                      labelText: 'Model',
                      labelStyle: TextStyle(color: AppTheme.muted),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('RUNS ON', style: TextStyle(color: AppTheme.muted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8)),
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
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _tankController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: TextStyle(color: AppTheme.text),
                    decoration: InputDecoration(
                      labelText: 'Tank (${_fuelType.unit})',
                      labelStyle: TextStyle(color: AppTheme.muted),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _reserveController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: TextStyle(color: AppTheme.text),
                    decoration: InputDecoration(
                      labelText: 'Reserve (${_fuelType.unit})',
                      labelStyle: TextStyle(color: AppTheme.muted),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _mileageController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: TextStyle(color: AppTheme.text),
                    decoration: InputDecoration(
                      labelText: 'km/${_fuelType.unit}',
                      labelStyle: TextStyle(color: AppTheme.muted),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _odometerController,
              keyboardType: TextInputType.number,
              style: TextStyle(color: AppTheme.text),
              decoration: InputDecoration(
                labelText: 'Current Odometer (km)',
                labelStyle: TextStyle(color: AppTheme.muted),
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: () {
                  final name = _nameController.text.trim();
                  if (name.isEmpty) {
                    setState(() => _nameError = 'Give your bike a name');
                    return;
                  }

                  final tank = double.tryParse(_tankController.text.trim()) ?? 15.0;
                  final reserve = double.tryParse(_reserveController.text.trim()) ?? 3.0;
                  final mileage = double.tryParse(_mileageController.text.trim()) ?? 25.0;
                  final odo = double.tryParse(_odometerController.text.trim()) ?? 0.0;

                  final newBike = BikeProfile(
                    id: 'bike_${DateTime.now().millisecondsSinceEpoch}',
                    name: name,
                    make: _makeController.text.trim(),
                    model: _modelController.text.trim(),
                    tankCapacityL: tank,
                    reserveCapacityL: reserve,
                    expectedMileageKmL: mileage,
                    totalOdometerKm: odo,
                    fuelType: _fuelType,
                  );

                  widget.onSave(newBike);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.brand,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: const Text(
                  'SAVE TO GARAGE',
                  style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.0),
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
