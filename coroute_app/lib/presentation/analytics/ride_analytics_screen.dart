import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/ride_analytics_service.dart';
import '../../data/services/safety_service.dart';
import '../../data/services/settings_service.dart';
import '../../data/services/trip_storage_service.dart';
import '../../domain/analytics/ride_analytics.dart';
import '../../domain/places/fuel_match.dart';
import '../feedback/suggest_feature_screen.dart';
import '../widgets/feature_switch.dart';

/// "Your ride analytics": totals, this month against last, km per week,
/// safety habits, fuel, group vs solo and streaks. Computed on the phone from
/// the saved trips (RideAnalyticsService); nothing leaves the phone.
/// Opened from Profile and from the Trips tab header.
class RideAnalyticsScreen extends StatefulWidget {
  const RideAnalyticsScreen({super.key});

  static const String privacyLine = 'Calculated on your phone. Only you can see this.';

  static Future<void> open(BuildContext context) async {
    // 3.55 admin feature switch: ride analytics turned off for every rider (every entry point).
    if (!context.featureOnNow('rideAnalytics')) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Ride analytics are turned off for now.')));
      return;
    }
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const RideAnalyticsScreen()));
  }

  @override
  State<RideAnalyticsScreen> createState() => _RideAnalyticsScreenState();
}

class _RideAnalyticsScreenState extends State<RideAnalyticsScreen> {
  RideAnalytics? _data;
  double? _price;
  int _loadedRevision = -1;
  bool _loading = false;
  bool _again = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    if (_loading) {
      _again = true;
      return;
    }
    _loading = true;
    try {
      final storage = context.read<TripStorageService>();
      final revision = storage.revision;
      SettingsService? settings;
      SafetyService? safety;
      try {
        settings = context.read<SettingsService>();
      } catch (_) {}
      try {
        safety = context.read<SafetyService>();
      } catch (_) {}
      _price = await RideAnalyticsService.fuelPrice();
      FuelInputs? fuel;
      if (settings != null) {
        final economy = safety?.fuelEconomy;
        try {
          await economy?.ensureLoaded();
        } catch (_) {}
        fuel = RideAnalyticsService.fuelInputsOf(
          profile: settings.fuelProfile,
          learning: economy?.learning,
          unit: economy?.fuelType.unit ?? 'L',
          pricePerUnit: _price,
        );
      }
      final data = await RideAnalyticsService.load(trips: storage.trips, revision: revision, fuel: fuel);
      if (!mounted) return;
      setState(() {
        _data = data;
        _loadedRevision = revision;
      });
    } catch (_) {
      if (mounted && _data == null) setState(() => _data = const RideAnalytics());
    } finally {
      _loading = false;
      if (_again && mounted) {
        _again = false;
        _load();
      }
    }
  }

  Future<void> _editPrice(String unit) async {
    final ctrl = TextEditingController(text: _price == null ? '' : _trimNum(_price!));
    final result = await showDialog<double?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Fuel price'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Price per $unit, for a rough cost. Kept on your phone only.', style: AppText.label),
            const SizedBox(height: Space.s12),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(hintText: 'For example, 105', suffixText: 'per $unit'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          if (_price != null) TextButton(onPressed: () => Navigator.pop(ctx, 0.0), child: const Text('Remove')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, double.tryParse(ctrl.text.trim().replaceAll(',', '.')) ?? -1),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (result == null || result < 0 || result > 100000) return;
    await RideAnalyticsService.setFuelPrice(result == 0 ? null : result);
    _load();
  }

  static String _trimNum(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final revision = context.select<TripStorageService, int>((s) => s.revision);
    if (_loadedRevision >= 0 && revision != _loadedRevision) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    final data = _data;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                  child: DsScreenHeader(
                    title: 'Your ride analytics',
                    subtitle: RideAnalyticsScreen.privacyLine,
                    onBack: () => Navigator.maybePop(context),
                  ),
                ),
                Expanded(
                  child: data == null
                      ? const Center(child: CircularProgressIndicator())
                      : data.isEmpty
                          ? _EmptyAnalytics(onSuggest: () => SuggestFeatureScreen.open(context))
                          : _AnalyticsBody(data: data, onEditPrice: _editPrice, onSuggest: () => SuggestFeatureScreen.open(context)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyAnalytics extends StatelessWidget {
  final VoidCallback onSuggest;
  const _EmptyAnalytics({required this.onSuggest});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      children: [
        const SizedBox(height: Space.s24),
        const EmptyState(
          icon: Icons.insights_rounded,
          title: 'Your stats start with your first ride',
          message: 'Finish a ride and you will see your distance, riding time, weekly progress and streaks here.',
        ),
        const SizedBox(height: Space.s24),
        _SuggestCard(onTap: onSuggest),
        const SizedBox(height: Space.s16),
        Text(RideAnalyticsScreen.privacyLine, textAlign: TextAlign.center, style: AppText.caption),
      ],
    );
  }
}

class _AnalyticsBody extends StatelessWidget {
  final RideAnalytics data;
  final void Function(String unit) onEditPrice;
  final VoidCallback onSuggest;
  const _AnalyticsBody({required this.data, required this.onEditPrice, required this.onSuggest});

  @override
  Widget build(BuildContext context) {
    final d = data;
    final streak = d.streakText;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      children: [
        if (streak != null) ...[
          DsCard(
            tinted: true,
            child: Row(
              children: [
                Icon(Icons.local_fire_department_rounded, color: AppTheme.warnText, size: 30),
                const SizedBox(width: Space.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(streak, style: AppText.title),
                      Text('Keep it going. Ride safe.', style: AppText.label),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.s16),
        ],
        const DsSectionHeader('All time'),
        const SizedBox(height: Space.s12),
        _Grid(cells: [
          ('Rides', '${d.rides}'),
          ('Distance', formatDistance(d.totalKm * 1000)),
          ('Riding time', formatDuration(Duration(milliseconds: d.ridingMs))),
          ('Longest ride', formatDistance(d.longestKm * 1000)),
          ('Top speed', d.topSpeedKmh > 0 ? '${d.topSpeedKmh.round()} km/h' : '-'),
          ('Avg moving speed', d.avgMovingKmh > 0 ? '${d.avgMovingKmh.round()} km/h' : '-'),
        ]),
        if (d.longestName.isNotEmpty) ...[
          const SizedBox(height: Space.s8),
          Text('Longest: ${d.longestName}', style: AppText.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
        const SizedBox(height: Space.s24),
        const DsSectionHeader('This month'),
        const SizedBox(height: Space.s12),
        _MonthCard(thisMonth: d.thisMonth, lastMonth: d.lastMonth),
        const SizedBox(height: Space.s24),
        const DsSectionHeader('Last 12 weeks'),
        const SizedBox(height: Space.s12),
        DsCard(child: WeeklyKmChart(weeks: d.weeks)),
        const SizedBox(height: Space.s24),
        const DsSectionHeader('Safety habits'),
        const SizedBox(height: Space.s12),
        _SafetyCard(safety: d.safety),
        if (d.fuel != null) ...[
          const SizedBox(height: Space.s24),
          const DsSectionHeader('Fuel'),
          const SizedBox(height: Space.s12),
          _FuelCard(fuel: d.fuel!, onEditPrice: () => onEditPrice(d.fuel!.unit)),
        ],
        const SizedBox(height: Space.s24),
        const DsSectionHeader('Group and solo'),
        const SizedBox(height: Space.s12),
        _SplitCard(data: d),
        const SizedBox(height: Space.s24),
        _SuggestCard(onTap: onSuggest),
        const SizedBox(height: Space.s16),
        Text(
          '${RideAnalyticsScreen.privacyLine}\n${_sourceLine(d)}',
          textAlign: TextAlign.center,
          style: AppText.caption,
        ),
      ],
    );
  }

  static String _sourceLine(RideAnalytics d) {
    if (d.fromAccount == 0) return 'All numbers come from your phone\'s own ride tracking.';
    if (d.fromPhone == 0) return 'Numbers come from your saved trip history.';
    return '${d.fromPhone} ${d.fromPhone == 1 ? 'ride' : 'rides'} from your phone\'s own tracking, ${d.fromAccount} from your saved trip history.';
  }
}

class _Grid extends StatelessWidget {
  final List<(String, String)> cells;
  const _Grid({required this.cells});

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < cells.length; i += 2) {
      rows.add(Row(
        children: [
          Expanded(child: DsStatCell(label: cells[i].$1, value: cells[i].$2)),
          const SizedBox(width: Space.s8),
          Expanded(child: i + 1 < cells.length ? DsStatCell(label: cells[i + 1].$1, value: cells[i + 1].$2) : const SizedBox()),
        ],
      ));
      if (i + 2 < cells.length) rows.add(const SizedBox(height: Space.s8));
    }
    return DsCard(padding: const EdgeInsets.all(12), child: Column(children: rows));
  }
}

class _MonthCard extends StatelessWidget {
  final PeriodTotals thisMonth;
  final PeriodTotals lastMonth;
  const _MonthCard({required this.thisMonth, required this.lastMonth});

  /// "40 km more than last month" and friends; never negative in tone.
  static String compare(PeriodTotals now, PeriodTotals before) {
    final diff = now.km - before.km;
    if (now.rides == 0 && before.rides == 0) return 'No rides yet this month or last. The road is waiting.';
    if (now.rides == 0) return 'No rides yet this month. Last month: ${formatDistance(before.km * 1000)}.';
    if (before.rides == 0) return 'Great start: more than last month already.';
    if (diff.abs() < 1) return 'Right on par with last month.';
    if (diff > 0) return '${formatDistance(diff * 1000)} more than last month. Nice.';
    return '${formatDistance(-diff * 1000)} to go to match last month.';
  }

  @override
  Widget build(BuildContext context) {
    Widget col(String title, PeriodTotals p) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppText.caption.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(formatDistance(p.km * 1000), style: AppText.title),
              Text('${p.rides} ${p.rides == 1 ? 'ride' : 'rides'} · ${formatDuration(Duration(milliseconds: p.ridingMs))}', style: AppText.label),
            ],
          ),
        );
    return DsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [col('This month', thisMonth), const SizedBox(width: Space.s12), col('Last month', lastMonth)]),
          const SizedBox(height: Space.s12),
          Text(compare(thisMonth, lastMonth), style: AppText.body),
        ],
      ),
    );
  }
}

/// Bars of km per week (oldest left, this week right), drawn with a
/// CustomPainter. Screen readers get one sentence per week instead of the drawing.
class WeeklyKmChart extends StatelessWidget {
  final List<WeekBar> weeks;
  const WeeklyKmChart({super.key, required this.weeks});

  static String weekLabel(WeekBar w) => DateFormat('d MMM').format(DateTime(w.year, w.month, w.day));

  static String semanticsOf(List<WeekBar> weeks) {
    if (weeks.isEmpty) return 'No weekly data.';
    final parts = <String>[
      for (var i = 0; i < weeks.length; i++)
        '${i == weeks.length - 1 ? 'This week' : 'Week of ${weekLabel(weeks[i])}'}: ${formatDistance(weeks[i].km * 1000)}',
    ];
    return 'Kilometres per week, last ${weeks.length} weeks. ${parts.join('. ')}.';
  }

  @override
  Widget build(BuildContext context) {
    final maxKm = weeks.fold<double>(0, (m, w) => w.km > m ? w.km : m);
    final label = DateFormat('d MMM');
    return Semantics(
      container: true,
      label: semanticsOf(weeks),
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(maxKm > 0 ? 'Best week: ${formatDistance(maxKm * 1000)}' : 'No rides in the last 12 weeks yet.', style: AppText.label),
            const SizedBox(height: Space.s12),
            SizedBox(
              height: 140,
              child: CustomPaint(
                painter: WeeklyBarsPainter(
                  values: [for (final w in weeks) w.km],
                  bar: AppTheme.brand,
                  current: AppTheme.accentText,
                  empty: AppTheme.border,
                ),
              ),
            ),
            const SizedBox(height: Space.s8),
            if (weeks.isNotEmpty)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(label.format(DateTime(weeks.first.year, weeks.first.month, weeks.first.day)), style: AppText.caption),
                  Text('This week', style: AppText.caption),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class WeeklyBarsPainter extends CustomPainter {
  final List<double> values;
  final Color bar;
  final Color current;
  final Color empty;
  WeeklyBarsPainter({required this.values, required this.bar, required this.current, required this.empty});

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty || size.width <= 0 || size.height <= 0) return;
    final maxV = values.fold<double>(0, (m, v) => v > m ? v : m);
    final slot = size.width / values.length;
    final w = (slot * 0.62).clamp(2.0, 40.0);
    final paint = Paint()..style = PaintingStyle.fill;
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      final x = i * slot + (slot - w) / 2;
      final h = maxV > 0 && v > 0 ? (v / maxV * (size.height - 4)).clamp(4.0, size.height) : 3.0;
      paint.color = v <= 0 ? empty : (i == values.length - 1 ? current : bar);
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(x, size.height - h, w, h),
          topLeft: const Radius.circular(5),
          topRight: const Radius.circular(5),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(WeeklyBarsPainter old) =>
      old.bar != bar || old.current != current || old.empty != empty || !_same(old.values, values);

  static bool _same(List<double> a, List<double> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _SafetyCard extends StatelessWidget {
  final SafetySummary safety;
  const _SafetyCard({required this.safety});

  @override
  Widget build(BuildContext context) {
    final s = safety;
    if (s.rides == 0) {
      return DsCard(
        child: Text('Your rest breaks and safety heads-ups will show here after your next ride.', style: AppText.label),
      );
    }
    return DsCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _line(Icons.free_breakfast_rounded, 'Rest breaks taken', '${s.breaks}',
              s.breaks > 0 ? 'Good habit. Rested riders react faster.' : 'A short stop every 2 hours keeps you sharp.'),
          _line(Icons.notifications_active_rounded, 'Safety heads-ups', '${s.alerts}',
              s.alerts > 0 ? 'CoRoute kept an eye out for you.' : 'Quiet rides. CoRoute is still watching out.'),
          _line(Icons.sos_rounded, 'SOS', s.sosRides == 0 ? 'Not needed' : '${s.sosRides}',
              s.sosRides == 0 ? 'Good to know it is there.' : 'We are glad it was there when you needed it.'),
          if (s.crashChecks > 0)
            _line(Icons.health_and_safety_rounded, 'Crash checks', '${s.crashChecks}', 'Each one checked you were OK.'),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text('From your rides on this phone in the last 90 days.', style: AppText.caption),
          ),
        ],
      ),
    );
  }

  Widget _line(IconData icon, String label, String value, String hint) {
    return MergeSemantics(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppTheme.border))),
        child: Row(
          children: [
            Icon(icon, size: 22, color: AppTheme.accentText),
            const SizedBox(width: Space.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
                  Text(hint, style: AppText.caption),
                ],
              ),
            ),
            const SizedBox(width: Space.s8),
            Text(value, style: AppText.title.copyWith(color: AppTheme.accentText)),
          ],
        ),
      ),
    );
  }
}

class _FuelCard extends StatelessWidget {
  final FuelSummary fuel;
  final VoidCallback onEditPrice;
  const _FuelCard({required this.fuel, required this.onEditPrice});

  static String amount(double v, String unit) => '${v >= 100 ? v.round() : v.toStringAsFixed(1)} $unit';
  static String money(double v) => NumberFormat.decimalPattern().format(v.round());

  @override
  Widget build(BuildContext context) {
    final f = fuel;
    final cells = <(String, String)>[
      ('Used this month', amount(f.usedThisMonth, f.unit)),
      ('Used in total', amount(f.usedTotal, f.unit)),
      if (f.costThisMonth != null) ('Cost this month', '≈ ${money(f.costThisMonth!)}'),
      if (f.costTotal != null) ('Cost in total', '≈ ${money(f.costTotal!)}'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Grid(cells: cells),
        const SizedBox(height: Space.s8),
        Row(
          children: [
            Expanded(child: Text('Estimated from your distance and your bike\'s mileage.', style: AppText.caption)),
            TextButton(
              onPressed: onEditPrice,
              child: Text(f.costTotal == null ? 'Add fuel price' : 'Change price'),
            ),
          ],
        ),
      ],
    );
  }
}

class _SplitCard extends StatelessWidget {
  final RideAnalytics data;
  const _SplitCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final d = data;
    final share = d.rides > 0 ? d.groupRides / d.rides : 0.0;
    String side(int n, double km) => '$n ${n == 1 ? 'ride' : 'rides'} · ${formatDistance(km * 1000)}';
    return DsCard(
      semanticsLabel: 'Group rides: ${side(d.groupRides, d.groupKm)}. Solo rides: ${side(d.soloRides, d.soloKm)}.',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DsProgressBar(value: share),
            const SizedBox(height: Space.s12),
            Row(
              children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Group', style: AppText.caption.copyWith(fontWeight: FontWeight.w700)),
                    Text(side(d.groupRides, d.groupKm), style: AppText.body),
                  ]),
                ),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text('Solo', style: AppText.caption.copyWith(fontWeight: FontWeight.w700)),
                    Text(side(d.soloRides, d.soloKm), style: AppText.body),
                  ]),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SuggestCard extends StatelessWidget {
  final VoidCallback onTap;
  const _SuggestCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return DsCard(
      key: const Key('analytics_suggest_feature'),
      onTap: onTap,
      semanticsLabel: 'Suggest a safety feature. Got an idea for safer rides? Tell us.',
      child: ExcludeSemantics(
        child: Row(
        children: [
          Icon(Icons.lightbulb_outline_rounded, color: AppTheme.accentText, size: 28),
          const SizedBox(width: Space.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Suggest a safety feature', style: AppText.body.copyWith(fontWeight: FontWeight.w800)),
                Text('Got an idea for safer rides? Tell us.', style: AppText.caption),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
        ],
        ),
      ),
    );
  }
}
