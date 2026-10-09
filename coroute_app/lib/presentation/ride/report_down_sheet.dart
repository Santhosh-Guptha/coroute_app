import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/rider_model.dart';
import '../../data/services/convoy_service.dart';

/// "Report a rider down here" (3.16, item 1): opened from the long-press
/// sheet on the ride map by any rider. Who is down is optional: one of my
/// group (their card then shows the alert) or "Someone not in my group".
/// Sends the existing REPORT_DOWN message through [ConvoyService.reportRiderDown]
/// (kept in the outbox without signal). Returns true when it was queued,
/// false when it could not be, null when the rider closed the sheet.
Future<bool?> showReportDownSheet(BuildContext context, {required double lat, required double lng, String placeName = ''}) {
  return showAppSheet<bool>(
    context,
    isScrollControlled: true,
    builder: (_) => ReportDownSheet(lat: lat, lng: lng, placeName: placeName),
  );
}

class ReportDownSheet extends StatefulWidget {
  final double lat;
  final double lng;
  final String placeName;

  const ReportDownSheet({super.key, required this.lat, required this.lng, this.placeName = ''});

  /// Marker value for "Someone not in my group".
  static const String nobody = '';

  @override
  State<ReportDownSheet> createState() => _ReportDownSheetState();
}

class _ReportDownSheetState extends State<ReportDownSheet> {
  String _subject = ReportDownSheet.nobody;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: L10n.changes,
      builder: (context, _, _) => _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final service = context.watch<ConvoyService>();
    final convoy = service.activeConvoy;
    final myId = service.myUserId ?? '';
    final riders = <RiderModel>[
      for (final r in convoy?.riders.values ?? const <RiderModel>[])
        if (r.userId != myId) r,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final Color red = StatusColors.critical;
    final place = widget.placeName.trim();

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(color: red.withOpacity(0.14), shape: BoxShape.circle),
                child: Icon(Icons.personal_injury_rounded, color: red, size: 28),
              ),
              const SizedBox(width: Space.s12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(L10n.t('report.title'), maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(fontWeight: FontWeight.w700)),
                    ),
                    if (place.isNotEmpty)
                      Text(place, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppText.label)
                    else
                      Text(
                        '${widget.lat.toStringAsFixed(5)}, ${widget.lng.toStringAsFixed(5)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.caption.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.s12),
          Text(L10n.t('report.body'), maxLines: 5, overflow: TextOverflow.ellipsis, style: AppText.body),
          if (riders.isNotEmpty) ...[
            const SizedBox(height: Space.s16),
            Semantics(header: true, child: Text(L10n.t('report.who'), style: AppText.label)),
            const SizedBox(height: Space.s8),
            Wrap(
              spacing: Space.s8,
              runSpacing: Space.s8,
              children: [
                ChoiceChip(
                  label: Text(L10n.t('report.other'), maxLines: 1, overflow: TextOverflow.ellipsis),
                  selected: _subject == ReportDownSheet.nobody,
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  onSelected: (_) => setState(() => _subject = ReportDownSheet.nobody),
                ),
                for (final r in riders)
                  ChoiceChip(
                    label: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    selected: _subject == r.userId,
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                    onSelected: (_) => setState(() => _subject = r.userId),
                  ),
              ],
            ),
          ],
          const SizedBox(height: Space.s24),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
              backgroundColor: red,
              foregroundColor: StatusColors.onCritical,
            ),
            onPressed: () {
              final ok = service.reportRiderDown(
                lat: widget.lat,
                lng: widget.lng,
                subjectUserId: _subject == ReportDownSheet.nobody ? null : _subject,
              );
              Navigator.of(context).pop(ok);
            },
            icon: const Icon(Icons.sos_rounded),
            label: Text(L10n.t('report.send'), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(height: Space.s8),
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48), foregroundColor: AppTheme.textPrimary),
            onPressed: () => Navigator.of(context).pop(),
            child: Text(L10n.t('sos.cancel'), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}
