import 'package:flutter/material.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/network_models.dart';
import '../../data/models/network_wire.dart';
import '../../domain/notify/relation.dart';
import 'emergency_guidance.dart';

/// "Active", "Responder arriving", "Assistance on scene".
String hazardLevelWords(HazardLevel level) {
  switch (level) {
    case HazardLevel.active:
      return L10n.t('hazard.level.active');
    case HazardLevel.responderArriving:
      return L10n.t('hazard.level.arriving');
    case HazardLevel.onScene:
      return L10n.t('hazard.level.onScene');
  }
}

/// "Accident reported 2.3 km ahead" / "Accident reported" for the map marker.
String hazardMarkerLabel(double? distanceM) =>
    distanceM == null ? L10n.t('hazard.marker') : L10n.t('hazard.marker.ahead', {'dist': Relation.distanceText(distanceM)});

/// Metres to a hazard and whether that is along my route: the phone's own
/// view when it has one, else what the server sent.
({double? distanceM, bool alongRoute}) hazardDistance(HazardWarning h, HazardView? view) {
  final v = view;
  if (v != null) return (distanceM: v.distanceM, alongRoute: v.alongRoute);
  return (distanceM: h.aheadM, alongRoute: h.onRoute);
}

/// "Rider accident reported 2.0 km ahead on your route. Reduce speed and stay alert."
String hazardMessage(HazardWarning h, HazardView? view) {
  final d = hazardDistance(h, view);
  final m = d.distanceM;
  final where = m == null
      ? L10n.t('hazard.where.none')
      : L10n.t(d.alongRoute ? 'hazard.where.route' : 'hazard.where.ahead', {'dist': Relation.distanceText(m)});
  return L10n.t('hazard.body', {'where': where});
}

/// The amber "CAUTION" banner for an accident reported ahead (another
/// group's emergency). Never red, no identity, no buttons needed while
/// riding; a tap shows it on the map. Static.
class HazardBanner extends StatelessWidget {
  final HazardWarning hazard;
  final HazardView? view;
  final VoidCallback? onTap;
  final VoidCallback? onDismiss;

  const HazardBanner({super.key, required this.hazard, this.view, this.onTap, this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final Color amber = StatusColors.warning;
    final message = hazardMessage(hazard, view);
    final level = hazardLevelWords(hazard.level);
    final dismiss = onDismiss;
    return Semantics(
      container: true,
      liveRegion: true,
      label: '${L10n.t('hazard.title')}. $message $level.',
      child: Material(
        color: Color.alphaBlend(amber.withOpacity(0.16), AppTheme.slateCard),
        elevation: 2,
        shadowColor: AppTheme.shadow,
        shape: RoundedRectangleBorder(borderRadius: Radii.mdAll, side: BorderSide(color: amber, width: 1.5)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Space.s12, Space.s8, Space.s4, Space.s8),
              child: ExcludeSemantics(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(Icons.warning_amber_rounded, color: amber, size: 28),
                    ),
                    const SizedBox(width: Space.s12),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(L10n.t('hazard.title').toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(fontWeight: FontWeight.w800)),
                          Text(message, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.body),
                          Text(level, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: AppTheme.textSecondary)),
                        ],
                      ),
                    ),
                    if (dismiss != null)
                      IconButton(
                        tooltip: 'Dismiss',
                        onPressed: dismiss,
                        icon: Icon(Icons.close_rounded, color: AppTheme.textSecondary),
                      )
                    else
                      const SizedBox(width: Space.s8),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A round map pin centred on the point with a short label under it (the
/// marker box is centred on the point, so the pin sits exactly there).
class _PinWithLabel extends StatelessWidget {
  final double width;
  final double height;
  final double pin;
  final Widget icon;
  final Widget label;

  const _PinWithLabel({required this.width, required this.height, required this.pin, required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          SizedBox(width: pin, height: pin, child: icon),
          Positioned(
            top: height / 2 + pin / 2 + 2,
            left: 0,
            right: 0,
            child: Center(child: label),
          ),
        ],
      ),
    );
  }
}

/// A small amber map marker for a reported accident, with a short label
/// ("Accident reported 2.3 km ahead"). No overlays, no animation.
class HazardMarker extends StatelessWidget {
  final String label;
  final HazardLevel level;

  /// Marker box size for flutter_map (width, height); the pin is at the centre.
  static const double width = 176;
  static const double height = 88;

  const HazardMarker({super.key, required this.label, this.level = HazardLevel.active});

  @override
  Widget build(BuildContext context) {
    final Color amber = StatusColors.warning;
    return Semantics(
      container: true,
      label: '$label. ${hazardLevelWords(level)}',
      excludeSemantics: true,
      child: _PinWithLabel(
        width: width,
        height: height,
        pin: 28,
        icon: Container(
          decoration: BoxDecoration(color: amber, shape: BoxShape.circle, border: Border.all(color: AppTheme.slateCard, width: 2)),
          child: Icon(Icons.warning_rounded, size: 16, color: AppTheme.obsidianVoid),
        ),
        label: Container(
          padding: const EdgeInsets.symmetric(horizontal: Space.s4, vertical: 2),
          decoration: BoxDecoration(color: AppTheme.slateCard, borderRadius: Radii.smAll, border: Border.all(color: amber)),
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: AppTheme.textPrimary)),
        ),
      ),
    );
  }
}

/// The red point of an emergency (the last known position; never removed
/// while the emergency is open). [label] is short ("Rahul", "Rider emergency").
class EmergencyPointMarker extends StatelessWidget {
  final String label;
  final String? detail;

  static const double width = 176;
  static const double height = 96;

  const EmergencyPointMarker({super.key, required this.label, this.detail});

  @override
  Widget build(BuildContext context) {
    final Color red = StatusColors.critical;
    final d = detail;
    return Semantics(
      container: true,
      label: d == null ? 'Emergency, $label' : 'Emergency, $label, $d',
      excludeSemantics: true,
      child: _PinWithLabel(
        width: width,
        height: height,
        pin: 32,
        icon: Container(
          decoration: BoxDecoration(color: red, shape: BoxShape.circle, border: Border.all(color: StatusColors.onCritical, width: 2)),
          child: Icon(Icons.emergency_rounded, size: 18, color: StatusColors.onCritical),
        ),
        label: Container(
          padding: const EdgeInsets.symmetric(horizontal: Space.s4, vertical: 2),
          decoration: BoxDecoration(color: red, borderRadius: Radii.smAll),
          child: Text(
            d == null ? label : '$label, $d',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(color: StatusColors.onCritical, fontWeight: FontWeight.w700),
          ),
        ),
      ),
    );
  }
}

/// A nearby responder from another group, only while they are on the way
/// (green, first name only).
class ResponderMarker extends StatelessWidget {
  final String name;

  static const double width = 140;
  static const double height = 88;

  const ResponderMarker({super.key, required this.name});

  @override
  Widget build(BuildContext context) {
    final Color green = StatusColors.success;
    final n = name.trim().isEmpty ? 'Responder' : name.trim();
    return Semantics(
      container: true,
      label: 'Nearby responder, $n',
      excludeSemantics: true,
      child: _PinWithLabel(
        width: width,
        height: height,
        pin: 28,
        icon: Container(
          decoration: BoxDecoration(color: green, shape: BoxShape.circle, border: Border.all(color: StatusColors.onCritical, width: 2)),
          child: Icon(Icons.health_and_safety_rounded, size: 16, color: StatusColors.onCritical),
        ),
        label: Container(
          padding: const EdgeInsets.symmetric(horizontal: Space.s4, vertical: 2),
          decoration: BoxDecoration(color: AppTheme.slateCard, borderRadius: Radii.smAll, border: Border.all(color: green)),
          child: Text(n, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption.copyWith(color: AppTheme.textPrimary)),
        ),
      ),
    );
  }
}
