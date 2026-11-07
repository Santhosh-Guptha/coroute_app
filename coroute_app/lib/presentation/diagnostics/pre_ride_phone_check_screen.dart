import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/device_diagnostic_report.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/device_diagnostic_service.dart';
import '../../data/services/permissions_service.dart';
import '../../data/services/safety_native.dart';
import '../../data/services/settings_service.dart';
import '../safety/oem_battery_guide.dart';
import '../safety/mount_check_line.dart';

/// Pre-ride phone check: a short checklist (pass / warn / fail) with a one-tap fix for each
/// problem and one plain verdict ("Ready to ride"). Nothing is ever blocked: before a ride
/// "Skip" and "Start the ride" are one tap; a failed safety item asks once to ride anyway.
/// Pops `true` to go on to the ride, `false` (or null) to stay.
class PreRidePhoneCheckScreen extends StatefulWidget {
  final bool autoRun;
  final String? triggerReason;

  /// Opened on the way into a ride (shows Skip / Start the ride). Also true with a [triggerReason].
  final bool beforeRide;

  const PreRidePhoneCheckScreen({
    super.key,
    this.autoRun = true,
    this.triggerReason,
    this.beforeRide = false,
  });

  /// Precise-location purpose key in Info.plist (NSLocationTemporaryUsageDescriptionDictionary).
  static const String precisePurposeKey = 'PreciseRiding';

  @override
  State<PreRidePhoneCheckScreen> createState() => _PreRidePhoneCheckScreenState();
}

class _PreRidePhoneCheckScreenState extends State<PreRidePhoneCheckScreen> with WidgetsBindingObserver {
  DeviceDiagnosticReport? _report;
  bool _isLoading = false;
  bool _isSubmitting = false;
  String? _submissionMessage;
  bool _consentGiven = false;
  String? _fixing;
  bool _rerunOnResume = false;
  bool _showPassed = false;

  bool get _beforeRide => widget.beforeRide || widget.triggerReason != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _initAndRun();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from a system settings page: read everything again.
    if (state == AppLifecycleState.resumed && _rerunOnResume && mounted) {
      _rerunOnResume = false;
      _runDiagnostics();
    }
  }

  Future<void> _initAndRun() async {
    final service = context.read<DeviceDiagnosticService>();
    final cached = await service.loadCachedReport();
    if (!mounted) return;
    if (cached != null) setState(() => _report = cached);
    if (widget.autoRun || cached == null) await _runDiagnostics();
  }

  Future<void> _runDiagnostics() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _submissionMessage = null;
    });
    try {
      final auth = context.read<AuthService?>();
      final service = context.read<DeviceDiagnosticService>();
      // Never take the microphone from the intercom while a ride is open.
      final inRide = context.read<ConvoyService?>()?.activeConvoy != null;
      final report = await service.runFullDiagnostic(
        riderId: auth?.currentUserId,
        riderEmail: auth?.currentUserEmail,
        micTest: !inRide,
      );
      if (!mounted) return;
      setState(() {
        _report = report;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('The check could not finish. Try again. ($e)'), backgroundColor: AppTheme.sos),
      );
    }
  }

  // ---------------------------------------------------------------- fixes

  static String _fixLabel(String fix) {
    switch (fix) {
      case PhoneCheckFix.locationService:
        return 'Turn on';
      case PhoneCheckFix.crashDetection:
        return 'Turn on';
      case PhoneCheckFix.retry:
        return 'Check again';
      case PhoneCheckFix.oemBattery:
        return 'Show steps';
      case PhoneCheckFix.sound:
      case PhoneCheckFix.appSettings:
      case PhoneCheckFix.fullScreen:
        return 'Open settings';
      default:
        return 'Allow';
    }
  }

  Future<void> _applyFix(DiagnosticCheckItem item) async {
    final fix = item.fix;
    if (fix == null || _fixing != null || _isLoading) return;
    setState(() => _fixing = item.key);
    var rerunNow = true;
    try {
      switch (fix) {
        case PhoneCheckFix.retry:
          break;
        case PhoneCheckFix.locationService:
          rerunNow = false;
          _rerunOnResume = true;
          await Geolocator.openLocationSettings();
        case PhoneCheckFix.appSettings:
          rerunNow = false;
          _rerunOnResume = true;
          await Geolocator.openAppSettings();
        case PhoneCheckFix.sound:
          rerunNow = false;
          _rerunOnResume = true;
          await SafetyNative.openSoundSettings();
        case PhoneCheckFix.locationAlways:
          final go = await _backgroundLocationDisclosure();
          if (!mounted) return;
          if (go) {
            await PermissionsService.request('locationAlways');
          } else {
            rerunNow = false;
          }
        case PhoneCheckFix.preciseLocation:
          await _askPrecise();
        case PhoneCheckFix.oemBattery:
          await OemBatteryGuide.show(context);
        case PhoneCheckFix.crashDetection:
          await Provider.of<SettingsService?>(context, listen: false)?.setCrashDetection(true);
        default:
          // location, notification, microphone, bluetooth, battery, fullScreen
          await PermissionsService.request(fix);
      }
    } catch (_) {
      // A settings page that does not exist on this phone: the check below shows the state.
    }
    if (!mounted) return;
    setState(() => _fixing = null);
    if (rerunNow) await _runDiagnostics();
  }

  Future<void> _askPrecise() async {
    if (!kIsWeb && Platform.isIOS) {
      await Geolocator.requestTemporaryFullAccuracy(purposeKey: PreRidePhoneCheckScreen.precisePurposeKey);
      return;
    }
    // Android 12+: asking again offers "Precise"; if the rider declined before, open settings.
    await Geolocator.requestPermission();
    if (await Geolocator.getLocationAccuracy() == LocationAccuracyStatus.reduced) {
      _rerunOnResume = true;
      await Geolocator.openAppSettings();
    }
  }

  /// Prominent disclosure (Google Play) before asking for "Allow all the time".
  Future<bool> _backgroundLocationDisclosure() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Location with the screen off'),
        content: const Text(
          'CoRoute collects your location to share your live position with your riding group and to '
          'send it with an SOS or crash alert, even when the app is closed or not in use. '
          'This happens only during an active ride and stops when the ride ends.\n\n'
          'On the next screen, choose "Allow all the time".',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No thanks')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Continue')),
        ],
      ),
    );
    return ok ?? false;
  }

  // ---------------------------------------------------------------- leaving

  Future<void> _rideAnyway(DeviceDiagnosticReport report) async {
    final fails = report.problems.where((c) => c.verdict == CheckVerdict.fail).toList();
    if (fails.isEmpty) {
      Navigator.pop(context, true);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ride without these?'),
        content: Text(
          '${fails.map((c) => '- ${c.name}: ${c.detail}').join('\n')}\n\nSome safety features will not work on this ride.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Go back')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ride anyway')),
        ],
      ),
    );
    if (ok == true && mounted) Navigator.pop(context, true);
  }

  // ---------------------------------------------------------------- UI

  static Color _verdictColor(CheckVerdict v) {
    switch (v) {
      case CheckVerdict.pass:
        return AppTheme.emeraldSafe;
      case CheckVerdict.warn:
        return AppTheme.warnText;
      case CheckVerdict.fail:
        return AppTheme.sos;
    }
  }

  static IconData _verdictIcon(CheckVerdict v) {
    switch (v) {
      case CheckVerdict.pass:
        return Icons.check_circle_rounded;
      case CheckVerdict.warn:
        return Icons.error_outline_rounded;
      case CheckVerdict.fail:
        return Icons.cancel_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = _report;
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        backgroundColor: AppTheme.bg,
        elevation: 0,
        title: const Text('Phone check', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        actions: [
          IconButton(
            tooltip: 'Check again',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _isLoading ? null : _runDiagnostics,
          ),
          if (_beforeRide)
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Skip'),
            ),
        ],
      ),
      body: SafeArea(
        child: _isLoading && report == null
            ? _buildRunningState()
            : report == null
                ? _buildEmptyState()
                : _buildReportView(report),
      ),
    );
  }

  Widget _buildRunningState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 48, height: 48, child: CircularProgressIndicator(strokeWidth: 3, color: AppTheme.brand)),
            const SizedBox(height: 20),
            Text('Checking your phone', style: AppText.title),
            const SizedBox(height: 8),
            Text(
              'GPS, sensors, alerts, sound, battery and SOS. About 10 seconds.',
              textAlign: TextAlign.center,
              style: AppText.body.copyWith(color: AppTheme.text2),
            ),
            if (_beforeRide) ...[
              const SizedBox(height: 24),
              TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Skip and ride')),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.phonelink_setup_rounded, size: 56, color: AppTheme.brand),
            const SizedBox(height: 16),
            Text('Check your phone before a ride', style: AppText.title, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              'Makes sure GPS, crash detection, alerts and SOS will work.',
              textAlign: TextAlign.center,
              style: AppText.body.copyWith(color: AppTheme.text2),
            ),
            const SizedBox(height: 24),
            DsButton(label: 'Check my phone', onPressed: _runDiagnostics),
          ],
        ),
      ),
    );
  }

  Widget _buildReportView(DeviceDiagnosticReport report) {
    final readiness = report.readiness;
    final problems = report.problems;
    final passed = [
      for (final e in report.categories.entries)
        if (e.key != 'device')
          for (final c in e.value.checks)
            if (c.verdict == CheckVerdict.pass) c,
    ];
    final fails = problems.where((c) => c.verdict == CheckVerdict.fail).length;
    final warns = problems.length - fails;

    final Color col;
    final IconData icon;
    final String headline;
    final String sub;
    switch (readiness) {
      case RideReadiness.ready:
        col = AppTheme.emeraldSafe;
        icon = Icons.verified_rounded;
        headline = 'Ready to ride';
        sub = 'Everything checked out.';
      case RideReadiness.readyWithWarnings:
        col = AppTheme.warnText;
        icon = Icons.verified_outlined;
        headline = 'Ready to ride';
        sub = '$warns ${warns == 1 ? 'thing' : 'things'} could be better. You can fix ${warns == 1 ? 'it' : 'them'} below.';
      case RideReadiness.notReady:
        col = AppTheme.sos;
        icon = Icons.gpp_maybe_rounded;
        headline = fails == 1 ? 'Fix 1 thing before you ride' : 'Fix $fails things before you ride';
        sub = 'Some safety features will not work until then.';
    }

    return Column(
      children: [
        if (_isLoading) LinearProgressIndicator(minHeight: 3, color: AppTheme.brand),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            children: [
              if (widget.triggerReason != null) ...[
                Text(widget.triggerReason!, style: AppText.caption.copyWith(color: AppTheme.text2)),
                const SizedBox(height: 10),
              ],
              DsCard(
                borderColor: col,
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(icon, color: col, size: 36),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(headline, style: AppText.headline.copyWith(color: col)),
                          const SizedBox(height: 4),
                          Text(sub, style: AppText.body.copyWith(color: AppTheme.text2)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (problems.isNotEmpty) ...[
                DsSectionHeader(fails > 0 ? 'Needs attention' : 'Could be better'),
                const SizedBox(height: 8),
                ...problems.map(_problemRow),
                const SizedBox(height: 12),
              ],
              InkWell(
                onTap: () => setState(() => _showPassed = !_showPassed),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle_rounded, color: AppTheme.emeraldSafe, size: 20),
                      const SizedBox(width: 8),
                      Expanded(child: Text('${passed.length} checks passed', style: AppText.label)),
                      Icon(_showPassed ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: AppTheme.muted),
                    ],
                  ),
                ),
              ),
              if (_showPassed) ...passed.map(_passRow),
              const SizedBox(height: 8),
              const MountCheckLine(), // 3.55 phone-mount check: where the phone was last ride
              _buildSubmissionTile(report),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: _beforeRide
              ? DsButton(
                  label: readiness == RideReadiness.notReady ? 'Ride anyway' : 'Start the ride',
                  icon: Icons.two_wheeler_rounded,
                  tone: readiness == RideReadiness.notReady ? DsButtonTone.warn : DsButtonTone.brand,
                  onPressed: _isLoading ? null : () => _rideAnyway(report),
                )
              : DsButton(label: 'Done', onPressed: () => Navigator.pop(context, readiness != RideReadiness.notReady)),
        ),
      ],
    );
  }

  Widget _problemRow(DiagnosticCheckItem c) {
    final v = c.verdict;
    final col = _verdictColor(v);
    final fix = c.fix;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DsCard(
        warning: v == CheckVerdict.warn,
        borderColor: v == CheckVerdict.fail ? col : null,
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: const EdgeInsets.only(top: 2), child: Icon(_verdictIcon(v), color: col, size: 22)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.name, style: AppText.label),
                  const SizedBox(height: 2),
                  Text(c.detail, style: AppText.caption.copyWith(color: AppTheme.text2)),
                ],
              ),
            ),
            if (fix != null) ...[
              const SizedBox(width: 8),
              _fixing == c.key
                  ? const Padding(
                      padding: EdgeInsets.all(10),
                      child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : TextButton(
                      onPressed: (_fixing != null || _isLoading) ? null : () => _applyFix(c),
                      child: Text(_fixLabel(fix)),
                    ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _passRow(DiagnosticCheckItem c) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.check_rounded, color: AppTheme.emeraldSafe, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '${c.name}  ', style: AppText.label),
                  TextSpan(text: c.detail, style: AppText.caption.copyWith(color: AppTheme.text2)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Optional: send this report to CoRoute support (explicit consent, data shown first).
  Widget _buildSubmissionTile(DeviceDiagnosticReport report) {
    final isSubmitted = report.lifecycleStatus == DiagnosticLifecycleStatus.submitted;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        title: Text('Share this report with CoRoute support', style: AppText.label),
        subtitle: Text(
          isSubmitted ? 'Sent.' : 'Optional. Helps us fix problems on your phone model.',
          style: AppText.caption.copyWith(color: AppTheme.text2),
        ),
        children: [
          Text(
            'Sent only if you agree. Never included: IMEI, serial number, contacts, messages, recordings, '
            'passwords or your location trail.',
            style: AppText.caption.copyWith(color: AppTheme.text2),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.data_object_rounded, size: 16),
              label: const Text('See exactly what is sent'),
              onPressed: () => _showInspectDataDialog(report),
            ),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _consentGiven || isSubmitted,
            onChanged: isSubmitted ? null : (v) => setState(() => _consentGiven = v ?? false),
            title: Text('I agree to send this report to CoRoute.', style: AppText.caption),
          ),
          if (_submissionMessage != null) ...[
            Text(
              _submissionMessage!,
              style: AppText.caption.copyWith(
                color: _submissionMessage!.startsWith('Could not') ? AppTheme.sos : AppTheme.emeraldSafe,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
          ],
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              icon: _isSubmitting
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.cloud_upload_rounded, size: 18),
              label: Text(isSubmitted ? 'Sent' : (_isSubmitting ? 'Sending...' : 'Send report')),
              onPressed: (!isSubmitted && _consentGiven && !_isSubmitting) ? () => _submitReport(report) : null,
            ),
          ),
        ],
      ),
    );
  }

  void _showInspectDataDialog(DeviceDiagnosticReport report) {
    final jsonStr = report.toJsonString(pretty: true);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('What is sent'),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: SingleChildScrollView(
            child: SelectableText(jsonStr, style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  Future<void> _submitReport(DeviceDiagnosticReport report) async {
    setState(() {
      _isSubmitting = true;
      _submissionMessage = null;
    });
    try {
      final service = context.read<DeviceDiagnosticService>();
      await service.submitReport(report, consentGiven: true);
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _submissionMessage = 'Report sent. Thank you.';
        _report = _report?.copyWith(lifecycleStatus: DiagnosticLifecycleStatus.submitted, consentGiven: true);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSubmitting = false;
        _submissionMessage = 'Could not send the report. Try again later.';
      });
    }
  }
}
