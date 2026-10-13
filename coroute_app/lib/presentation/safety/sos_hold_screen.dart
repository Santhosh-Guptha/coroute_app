import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/safety_native.dart';

/// Pale rose used for secondary text on the solid red SOS screens.
const Color sosPale = Color(0xFFFFD0D7);

/// "12.93°N 77.68°E" for the top row of the red screens.
String sosPositionWords(double lat, double lng) {
  final ns = lat >= 0 ? 'N' : 'S';
  final ew = lng >= 0 ? 'E' : 'W';
  return '${lat.abs().toStringAsFixed(2)}°$ns ${lng.abs().toStringAsFixed(2)}°$ew';
}

/// Top row of the red screens: an overline on the left ("EMERGENCY",
/// "Automatic alert") and the position on the right when known.
class SosTopRow extends StatelessWidget {
  final String overline;
  final double? lat;
  final double? lng;

  const SosTopRow({super.key, required this.overline, this.lat, this.lng});

  @override
  Widget build(BuildContext context) {
    final la = lat, ln = lng;
    final hasPos = la != null && ln != null && !(la == 0 && ln == 0);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            overline,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: sosPale, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 2, height: 1.3),
          ),
        ),
        if (hasPos) ...[
          const SizedBox(width: 12),
          Text(
            sosPositionWords(la, ln),
            maxLines: 1,
            style: const TextStyle(color: sosPale, fontSize: 12, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]),
          ),
        ],
      ],
    );
  }
}

/// The 140 px ring in the middle of the red screens (white 12 % fill,
/// 4 px white 50 % border) around the countdown or the hold button.
class SosRing extends StatelessWidget {
  final Widget child;
  final double size;
  const SosRing({super.key, required this.child, this.size = 140});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.5), width: 4),
      ),
      child: child,
    );
  }
}

/// One row of [SosAlertList] (pure, for tests): who is alerted and how.
class SosAlertRow {
  final IconData icon;
  final String label;
  final String how;
  const SosAlertRow({required this.icon, required this.label, required this.how});
}

/// Who gets alerted by an SOS, from what the phone knows: the other riders
/// of the active convoy (initials), the rider's emergency contact, and the
/// highway helpline the SOS sheet offers to dial. Nothing is invented: a
/// row is left out when the phone does not have that contact.
class SosAlertList extends StatelessWidget {
  const SosAlertList({super.key});

  static const int maxInitials = 4;

  /// The rows from the services (pure, for tests).
  static List<SosAlertRow> rowsFor({
    required List<String> otherRiderNames,
    required String emergencyContactName,
    required bool hasEmergencyContact,
  }) {
    final initials = <String>[];
    for (final n in otherRiderNames) {
      if (n.trim().isEmpty) continue;
      initials.add(initialsOf(n));
    }
    String convoy = 'Convoy riders';
    if (initials.isNotEmpty) {
      final shown = initials.take(maxInitials).join(', ');
      final more = initials.length - maxInitials;
      convoy = 'Convoy riders ($shown${more > 0 ? ' +$more' : ''})';
    }
    final name = emergencyContactName.trim();
    return [
      SosAlertRow(icon: Icons.group_outlined, label: convoy, how: 'Voice + location'),
      if (hasEmergencyContact)
        SosAlertRow(
          icon: Icons.phone_outlined,
          label: name.isEmpty ? 'Emergency contact' : '$name (emergency contact)',
          how: 'SMS + call',
        ),
      const SosAlertRow(icon: Icons.warning_amber_rounded, label: 'Highway helpline 1073', how: 'Call'),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final convoys = Provider.of<ConvoyService?>(context, listen: false);
    final auth = Provider.of<AuthService?>(context, listen: false);
    final me = convoys?.myUserId;
    final riders = convoys?.activeConvoy?.riders.values;
    final others = <String>[
      if (riders != null)
        for (final r in riders)
          if (r.userId != me) r.name,
    ];
    final phone = (auth?.emergencyContact ?? '').trim();
    final rows = rowsFor(
      otherRiderNames: others,
      emergencyContactName: auth?.emergencyContactName ?? '',
      hasEmergencyContact: phone.isNotEmpty,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < rows.length; i++)
            Container(
              constraints: const BoxConstraints(minHeight: 54),
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                border: i < rows.length - 1
                    ? Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.2)))
                    : null,
              ),
              child: Row(
                children: [
                  Icon(rows[i].icon, size: 22, color: Colors.white),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      rows[i].label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700, height: 1.25),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      rows[i].how,
                      maxLines: 2,
                      textAlign: TextAlign.end,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: sosPale, fontSize: 12, fontWeight: FontWeight.w800, height: 1.25),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// White 72 px button with red text ("I'm OK", "Cancel") on the red screens.
ButtonStyle sosPrimaryButtonStyle({double height = 72}) => FilledButton.styleFrom(
      backgroundColor: Colors.white,
      foregroundColor: AppTheme.sos,
      disabledBackgroundColor: Colors.white.withValues(alpha: 0.6),
      minimumSize: Size.fromHeight(height),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(20))),
      textStyle: const TextStyle(fontFamily: AppTheme.fontFamily, fontSize: 20, fontWeight: FontWeight.w800),
    );

/// Outlined white button ("Send now, don't wait") on the red screens.
ButtonStyle sosOutlineButtonStyle({double height = 56}) => FilledButton.styleFrom(
      backgroundColor: Colors.transparent,
      foregroundColor: Colors.white,
      minimumSize: Size.fromHeight(height),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      side: BorderSide(color: Colors.white.withValues(alpha: 0.6), width: 2),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(16))),
      textStyle: const TextStyle(fontFamily: AppTheme.fontFamily, fontSize: 16, fontWeight: FontWeight.w800),
    );

/// The caption under the buttons of the red screens.
class SosCaption extends StatelessWidget {
  const SosCaption({super.key});

  static const String text = 'Keep the phone on you. Your location updates every 10 s.';

  @override
  Widget build(BuildContext context) {
    return const Text(
      text,
      textAlign: TextAlign.center,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: sosPale, fontSize: 12, fontWeight: FontWeight.w600, height: 1.3),
    );
  }
}

/// The SOS screen opened from the ride notification (also over the lock
/// screen). Nothing is sent by opening it: the rider holds the big SOS
/// button for 1.5 s ([SOSButton]) or taps Cancel. Full screen, red, big
/// targets, no typing, no scrolling needed. Texts follow the rider's
/// language ([L10n], 3.16).
///
/// [show] returns true when the SOS was triggered (the caller then sends it
/// through the normal SOS path and shows the delivery sheet). On close the
/// lock-screen window flag set for this launch is cleared
/// ([SafetyNative.alarmWindow]).
class SosHoldScreen extends StatelessWidget {
  final VoidCallback onSend;
  final VoidCallback onCancel;

  const SosHoldScreen({super.key, required this.onSend, required this.onCancel});

  /// The hold button sits inside the 140 px [SosRing] (its own progress ring adds 12).
  static const double buttonSize = 104;

  static bool _open = false;

  /// True while the screen is showing (a second request does not open another one).
  static bool get isOpen => _open;

  /// The heading in the rider's language (read at build time).
  static String get title => L10n.t('sos.hold.title');

  /// Opens the hold screen on [context]'s navigator. True when the rider held SOS.
  static Future<bool> show(BuildContext context) async {
    if (_open) return false;
    _open = true;
    try {
      final sent = await Navigator.of(context, rootNavigator: true).push<bool>(
        MaterialPageRoute<bool>(
          fullscreenDialog: true,
          builder: (ctx) => SosHoldScreen(
            onSend: () => Navigator.of(ctx).pop(true),
            onCancel: () => Navigator.of(ctx).pop(false),
          ),
        ),
      );
      return sent ?? false;
    } finally {
      _open = false;
      SafetyNative.alarmWindow(false).ignore();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: L10n.changes,
      builder: (context, _, _) => _body(context),
    );
  }

  Widget _body(BuildContext context) {
    // My last fix, for the top row (none without a ride).
    final convoys = Provider.of<ConvoyService?>(context, listen: false);
    final uid = convoys?.myUserId;
    final me = uid == null ? null : convoys?.activeConvoy?.riders[uid];
    final top = SosTopRow(overline: 'EMERGENCY', lat: me?.lat, lng: me?.lng);
    final heading = Semantics(
      header: true,
      liveRegion: true,
      child: Text(
        title,
        textAlign: TextAlign.center,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.3, height: 1.15),
      ),
    );
    final help = Text(
      L10n.t('sos.hold.hint'),
      textAlign: TextAlign.center,
      maxLines: 8,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: sosPale, fontSize: 15, fontWeight: FontWeight.w600, height: 1.35),
    );
    final hold = Center(
      child: Semantics(
        container: true,
        button: true,
        label: L10n.t('sos.hold.label'),
        hint: L10n.t('sos.hold.action'),
        excludeSemantics: true,
        onLongPress: onSend,
        child: SosRing(child: SOSButton(onTriggered: onSend, size: buttonSize)),
      ),
    );
    final cancel = FilledButton.icon(
      onPressed: onCancel,
      style: sosPrimaryButtonStyle(),
      icon: const Icon(Icons.close_rounded, size: 24),
      label: Text(L10n.t('sos.cancel'), maxLines: 1, overflow: TextOverflow.ellipsis),
    );
    final bottom = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [cancel, const SizedBox(height: 12), const SosCaption()],
    );
    const list = SosAlertList();
    return PopScope(
      canPop: true,
      child: Scaffold(
        backgroundColor: AppTheme.sos,
        body: SafeArea(
          child: LayoutBuilder(builder: (context, box) {
            final wide = box.maxWidth > box.maxHeight && box.maxWidth >= 480;
            if (wide) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Row(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            top,
                            const SizedBox(height: 14),
                            heading,
                            const SizedBox(height: 8),
                            help,
                            const SizedBox(height: 16),
                            list,
                            const SizedBox(height: 16),
                            bottom,
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    // The hold button shrinks on a very low landscape screen instead of overflowing.
                    Expanded(child: FittedBox(fit: BoxFit.scaleDown, child: hold)),
                  ],
                ),
              );
            }
            return SingleChildScrollView(
              padding: dsScreenPadding,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: box.maxHeight > 44 ? box.maxHeight - 44 : 0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        top,
                        const SizedBox(height: 24),
                        hold,
                        const SizedBox(height: 14),
                        heading,
                        const SizedBox(height: 10),
                        help,
                        const SizedBox(height: 20),
                        list,
                      ],
                    ),
                    Padding(padding: const EdgeInsets.only(top: 20), child: bottom),
                  ],
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}
