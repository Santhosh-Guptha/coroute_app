import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/constants/emergency_nav_constants.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/network_models.dart';
import '../../data/models/network_wire.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/sms_sender.dart';
import '../../domain/notify/relation.dart';
import '../safety/safety_card_sheet.dart';
import 'assist_banner.dart';
import 'emergency_guidance.dart';
import 'incident_banner.dart';
import 'incident_sheet.dart';
import 'incident_view.dart';
import 'navigate_to.dart';

bool _isAssistSheetShowing = false;

/// Opens the sheet of an assistance request from another group.
Future<void> showAssistSheet(BuildContext context, {required String incidentId}) async {
  if (_isAssistSheetShowing) return;
  _isAssistSheetShowing = true;
  try {
    await showAppSheet<void>(
      context,
      isScrollControlled: true,
      builder: (_) => SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        child: AssistSheetBody(incidentId: incidentId),
      ),
    );
  } finally {
    _isAssistSheetShowing = false;
  }
}

/// The request in the service's lists (my accepted one first), or null when it closed.
AssistRequest? findAssist(ConvoyService service, String incidentId) {
  final active = service.activeAssist;
  if (active != null && active.incidentId == incidentId) return active;
  for (final a in service.assistRequests) {
    if (a.incidentId == incidentId) return a;
  }
  return null;
}

/// The assistance sheet: the same words as the banner, after I accepted the
/// rider's first name and vehicle (and medical info only when the rider
/// chose to share it with responders), the big answer buttons, "Call
/// emergency services 112", "Open in Google Maps" and "Report false alert"
/// (with a confirm). Before I accept it shows no name, no group and nothing
/// about the rider. Follows live changes; when the request closes it says why.
class AssistSheetBody extends StatelessWidget {
  final String incidentId;

  /// For "Last location update" in tests; defaults to now.
  final int? nowMs;

  const AssistSheetBody({super.key, required this.incidentId, this.nowMs});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: L10n.changes,
      builder: (context, _, _) => _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final service = context.watch<ConvoyService>();
    final guidance = context.watch<EmergencyGuidance?>();
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final a = findAssist(service, incidentId);
    if (a == null) return _closed(context, service);

    final convoy = service.activeConvoy;
    final uid = service.myUserId ?? '';
    final me = convoy?.riders[uid];
    final myLat = (me == null || (me.lat == 0 && me.lng == 0)) ? null : me.lat;
    final myLng = myLat == null ? null : me?.lng;
    final navigating = guidance != null && guidance.isTarget(NavTargetKind.assist, a.incidentId);
    final liveM = (guidance != null && navigating) ? guidance.remainingM : null;
    final distance = AssistTexts.distanceOf(a, myLat: myLat, myLng: myLng, liveM: liveM);
    final stage = assistStageOf(a, near: distance <= EmergencyNavConstants.arrivalAskM);
    final accepted = stage != AssistStage.request && stage != AssistStage.closed;
    final subject = accepted ? a.subject : null;
    final medical = accepted ? a.medical : null;
    final etaS = (guidance != null && navigating) ? guidance.eta?.inSeconds : a.etaS;

    final title = switch (stage) {
      AssistStage.request || AssistStage.closed => AssistTexts.requestTitle,
      AssistStage.responding => AssistTexts.respondingTitle(a, distance),
      AssistStage.arrivalCheck => AssistTexts.arrivalQuestion,
      AssistStage.onScene => AssistTexts.withRider,
    };

    Widget big(IconData icon, String label, VoidCallback onTap, {bool outlined = false, Color? color}) {
      final tone = outlined
          ? DsButtonTone.outline
          : color == AppTheme.sos
              ? DsButtonTone.sos
              : DsButtonTone.brand;
      return DsButton(label: label, icon: icon, tone: tone, onPressed: onTap);
    }

    ButtonStyle dial({required Color color, double height = 56, double fontSize = 14}) => OutlinedButton.styleFrom(
          foregroundColor: color,
          backgroundColor: AppTheme.card,
          side: BorderSide(color: color.withValues(alpha: 0.7), width: 2),
          minimumSize: Size.fromHeight(height),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: TextStyle(fontFamily: AppTheme.fontFamily, fontWeight: FontWeight.w800, fontSize: fontSize),
        );

    final List<Widget> actions;
    switch (stage) {
      case AssistStage.request:
      case AssistStage.closed:
        actions = [
          big(Icons.volunteer_activism_outlined, L10n.t('assist.help'), () => acceptAssist(context, a), color: AppTheme.sos),
          const SizedBox(height: Space.s8),
          big(Icons.navigation_outlined, L10n.t('incident.navigate'), () => navigateToAssist(context, a), outlined: true),
          const SizedBox(height: Space.s8),
          big(Icons.block_rounded, L10n.t('assist.cant'), () {
            sendAssistAnswer(context, a.incidentId, AssistAnswer.decline);
            Navigator.of(context).maybePop();
          }, outlined: true),
        ];
        break;
      case AssistStage.responding:
        actions = [
          big(Icons.navigation_outlined, L10n.t('incident.navigate'), () => navigateToAssist(context, a), color: AppTheme.sos),
          const SizedBox(height: Space.s8),
          big(Icons.flag_outlined, L10n.t('assist.arrived'), () => sendAssistAnswer(context, a.incidentId, AssistAnswer.arrived), outlined: true),
          const SizedBox(height: Space.s8),
          big(Icons.do_not_disturb_on_rounded, L10n.t('assist.unable'), () => sendAssistAnswer(context, a.incidentId, AssistAnswer.unable), outlined: true),
        ];
        break;
      case AssistStage.arrivalCheck:
        actions = [
          big(Icons.check_circle_outline_rounded, L10n.t('assist.found'), () => sendAssistAnswer(context, a.incidentId, AssistAnswer.arrived)),
          const SizedBox(height: Space.s8),
          big(Icons.location_searching_rounded, L10n.t('assist.notFound'), () => sendAssistAnswer(context, a.incidentId, AssistAnswer.notFound), outlined: true),
        ];
        break;
      case AssistStage.onScene:
        actions = const [];
        break;
    }

    final vehicle = subject == null
        ? ''
        : [subject.vehicleColor.trim(), subject.vehicleType.trim()].where((x) => x.isNotEmpty).join(' ');
    final updated = a.lastUpdateAt > 0 ? Relation.lastUpdate(a.lastUpdateAt, now) : null;
    final eta = etaWords(etaS);
    final far = stage == AssistStage.request ? AssistTexts.farBody(a) : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          container: true,
          liveRegion: true,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(color: AppTheme.sos.withValues(alpha: 0.12), shape: BoxShape.circle),
                child: Icon(Icons.emergency_share_outlined, color: AppTheme.sos, size: 26),
              ),
              const SizedBox(width: Space.s12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(title, maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.title.copyWith(fontSize: 18)),
                    ),
                    const SizedBox(height: 2),
                    if (a.farByRoad)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(AssistTexts.farLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: AppTheme.warnText, fontWeight: FontWeight.w700)),
                      ),
                    Text(AssistTexts.what(a), maxLines: 3, overflow: TextOverflow.ellipsis, style: AppText.label.copyWith(color: AppTheme.sos, fontWeight: FontWeight.w700)),
                    Text(
                      AssistTexts.where(a, myLat: myLat, myLng: myLng, route: convoy?.routeLine ?? const []),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.body.copyWith(fontWeight: FontWeight.w700),
                    ),
                    if (eta != null) Text(eta, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.body),
                    if (updated != null) Text(updated, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Space.s12),
        if (far != null) ...[
          Text(far, style: AppText.body.copyWith(color: AppTheme.text2)),
          const SizedBox(height: Space.s12),
        ] else if (stage == AssistStage.request && a.fasterThanGroup) ...[
          Text(AssistTexts.faster, style: AppText.body.copyWith(color: AppTheme.text2)),
          const SizedBox(height: Space.s12),
        ],
        if (accepted && stage != AssistStage.onScene) ...[
          PositiveLine(text: AssistTexts.responding),
          const SizedBox(height: Space.s12),
        ],
        if (subject != null && subject.firstName.trim().isNotEmpty)
          InfoLine(icon: Icons.person_outline_rounded, text: L10n.t('assist.rider', {'name': subject.firstName.trim()})),
        if (vehicle.isNotEmpty) InfoLine(icon: Icons.two_wheeler_rounded, text: L10n.t('assist.vehicle', {'vehicle': vehicle})),
        if (medical != null && !medical.isEmpty) ...[
          const SizedBox(height: Space.s8),
          MedicalCard(info: medical),
          const SizedBox(height: Space.s8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: () => SafetyCardSheet.show(context, name: subject?.firstName.trim() ?? '', medical: medical),
            icon: const Icon(Icons.medical_information_outlined),
            label: Text(L10n.t('incident.card'), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
        if (subject != null || vehicle.isNotEmpty || medical != null) const SizedBox(height: Space.s12),
        ...actions,
        const SizedBox(height: Space.s16),
        OutlinedButton.icon(
          style: dial(color: AppTheme.sos, fontSize: 15),
          onPressed: () => dialNumber(context, '112'),
          icon: const Icon(Icons.local_hospital_outlined),
          label: Text(L10n.t('assist.call112'), maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(height: Space.s8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                style: dial(color: AppTheme.sos, height: 52, fontSize: 12),
                onPressed: () => dialNumber(context, '108'),
                icon: const Icon(Icons.local_hospital_outlined, size: 18),
                label: const Text('Call 108 (Ambulance)', maxLines: 2, textAlign: TextAlign.center),
              ),
            ),
            const SizedBox(width: Space.s8),
            Expanded(
              child: OutlinedButton.icon(
                style: dial(color: AppTheme.sos, height: 52, fontSize: 12),
                onPressed: () => dialNumber(context, '100'),
                icon: const Icon(Icons.local_police_outlined, size: 18),
                label: const Text('Call 100 (Police)', maxLines: 2, textAlign: TextAlign.center),
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.s8),
        OutlinedButton.icon(
          style: dial(color: AppTheme.warnText, height: 48, fontSize: 12),
          onPressed: () => dialNumber(context, '1073'),
          icon: const Icon(Icons.emergency_outlined, size: 18),
          label: const Text('Call 1073 (NHAI Highway Helpline)', maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(height: Space.s8),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: () => SmsSender.launchSmsIntent(
            to: '',
            body: 'Emergency Assist at Lat:${a.lat.toStringAsFixed(5)}, Lng:${a.lng.toStringAsFixed(5)}. Maps: https://maps.google.com/?q=${a.lat.toStringAsFixed(5)},${a.lng.toStringAsFixed(5)} NHAI: 1073. ERSS: 112',
          ),
          icon: const Icon(Icons.sms_outlined, size: 18),
          label: const Text('Send Emergency SMS (No Permission Required)', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13)),
        ),
        const SizedBox(height: Space.s8),
        TextButton.icon(
          style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48), foregroundColor: AppTheme.text),
          onPressed: () async {
            final ok = await navigateTo(a.lat, a.lng, label: 'Emergency');
            if (!ok && context.mounted) {
              ScaffoldMessenger.of(context).clearSnackBars();
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No map app found on this phone.')));
            }
          },
          icon: const Icon(Icons.map_outlined),
          label: const Text('Open in Google Maps', maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        TextButton.icon(
          style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48), foregroundColor: AppTheme.muted),
          onPressed: () => reportFalseAssist(context, a.incidentId),
          icon: const Icon(Icons.report_gmailerrorred_rounded),
          label: const Text('Report false alert', maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }

  Widget _closed(BuildContext context, ConvoyService service) {
    var taken = false;
    for (final n in service.assistNotices) {
      if (n.incidentId == incidentId && n.reason == AssistClosedReason.taken) taken = true;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.s16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 56,
            height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: AppTheme.tint, shape: BoxShape.circle),
            child: Icon(taken ? Icons.directions_run_rounded : Icons.check_circle_outline_rounded, size: 32, color: AppTheme.accentText),
          ),
          const SizedBox(height: Space.s12),
          Text(taken ? AssistTexts.takenTitle : 'This request is closed', textAlign: TextAlign.center, style: AppText.title.copyWith(fontSize: 18)),
          const SizedBox(height: Space.s4),
          Text(
            taken ? AssistTexts.takenBody : 'No assistance is needed from you any more.',
            textAlign: TextAlign.center,
            style: AppText.body.copyWith(color: AppTheme.text2),
          ),
          const SizedBox(height: 20),
          DsButton(
            label: 'Close',
            tone: DsButtonTone.outline,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }
}

/// "Report false alert": asks first, then tells CoRoute once.
Future<void> reportFalseAssist(BuildContext context, String incidentId) async {
  final ok = await confirmAction(
    context,
    title: 'Report a false alert?',
    message: 'Tell CoRoute this request looks wrong. Do this only if you are sure there is no emergency.',
    confirmLabel: 'Report',
    destructive: true,
  );
  if (!ok || !context.mounted) return;
  final sent = context.read<ConvoyService>().reportFalseAlert(incidentId);
  if (context.mounted) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(sent ? 'Thank you. CoRoute was told.' : 'Already reported, or could not send it.'),
    ));
  }
}
