import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/rider_model.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/convoy_service.dart';
import '../account/edit_profile_screen.dart';
import '../onboarding/permissions_screen.dart';
import '../trip_planner/trip_planner_screen.dart';
import '../widgets/pre_ride_checklist_sheet.dart';

/// The Ride tab when no ride is active: "No active ride" with
/// [Start Ride] [Join Ride], and at most one alert above it.
class RideStartView extends StatelessWidget {
  /// Shows "Ride saved. View the summary" (after a ride ended while the app was open).
  final bool showRideSaved;
  final VoidCallback? onViewSummary;
  final VoidCallback? onDismissRideSaved;

  const RideStartView({
    super.key,
    this.showRideSaved = false,
    this.onViewSummary,
    this.onDismissRideSaved,
  });

  static bool _needsProfile(AuthService auth) => !auth.isProfileComplete && !auth.isMasterAdmin;

  /// Opens the one profile editor. Returns true when the profile is complete afterwards.
  static Future<bool> openProfile(BuildContext context) async {
    await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const EditProfileScreen()));
    if (!context.mounted) return false;
    return !_needsProfile(context.read<AuthService>());
  }

  /// [Start Ride]: safety details first (when missing), then the trip planner.
  static Future<void> startRide(BuildContext context) async {
    if (_needsProfile(context.read<AuthService>())) {
      final ok = await openProfile(context);
      if (!ok || !context.mounted) return;
    }
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const TripPlannerScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final needsProfile = _needsProfile(auth);
    Widget? alert;
    if (needsProfile) {
      alert = RideAlert(
        tier: AlertTier.important,
        title: 'Add your safety details',
        message: 'Your group needs your phone number and an emergency contact before you ride.',
        actionLabel: 'Add details',
        onAction: () => openProfile(context),
      );
    } else if (showRideSaved) {
      alert = RideAlert(
        tier: AlertTier.normal,
        title: 'Ride saved',
        message: 'Your trip is in Trips.',
        actionLabel: 'View the summary',
        onAction: onViewSummary,
        onDismiss: onDismissRideSaved,
      );
    }
    final a = alert;

    return Scaffold(
      backgroundColor: AppTheme.obsidianVoid,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(AppConstants.appName, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (a != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(Space.s16, Space.s8, Space.s16, 0),
                child: Center(
                  child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: a),
                ),
              ),
            Expanded(
              child: EmptyState(
                icon: Icons.two_wheeler_rounded,
                title: 'No active ride',
                message: 'Start a ride and share the code, or join with a code from your group.',
                primaryLabel: 'Start Ride',
                onPrimary: () => startRide(context),
                secondaryLabel: 'Join Ride',
                onSecondary: () => showJoinRideSheet(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// [Join Ride] and join links: a sheet with the code field. After a
/// successful join it shows the pre-ride checklist and returns to the shell,
/// which switches to the Ride tab by itself (it listens to the active ride).
Future<void> showJoinRideSheet(BuildContext context, {String? initialCode}) async {
  // The join makes the ride active, so the shell swaps this Ride tab (and [context] with it)
  // for the ride map right away. The checklist is shown from the navigator, which stays.
  final nav = Navigator.of(context);
  final navContext = nav.context;
  final joined = await showAppSheet<bool>(
    context,
    title: 'Join a ride',
    isScrollControlled: true,
    builder: (_) => JoinRideSheet(initialCode: initialCode),
  );
  if (joined != true || !navContext.mounted) return;
  await PreRideChecklistSheet.show(navContext);
  if (!navContext.mounted) return;
  nav.popUntil((r) => r.isFirst);
}

/// Body of the join sheet: code field, the profile gate as an inline
/// message, and [Join] at 56 dp.
class JoinRideSheet extends StatefulWidget {
  final String? initialCode;
  const JoinRideSheet({super.key, this.initialCode});

  @override
  State<JoinRideSheet> createState() => _JoinRideSheetState();
}

class _JoinRideSheetState extends State<JoinRideSheet> {
  late final TextEditingController _code = TextEditingController(text: widget.initialCode ?? '');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    final code = _code.text.trim();
    if (code.length < 4) {
      setState(() => _error = 'Enter the code your group shared with you.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final auth = context.read<AuthService>();
    final convoyService = context.read<ConvoyService>();

    if (!await PermissionsScreen.ensure(context)) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) return;

    // Last known position (or a quick fix) so the group sees where we join from.
    double joinLat = 0.0;
    double joinLng = 0.0;
    try {
      final pos = await Geolocator.getLastKnownPosition() ??
          await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.medium,
              timeLimit: Duration(seconds: 1),
            ),
          );
      joinLat = pos.latitude;
      joinLng = pos.longitude;
    } catch (_) {}

    final rider = RiderModel(
      userId: auth.currentUserId ?? '',
      name: auth.currentUserName ?? 'Rider',
      vehicleType: auth.vehicleType ?? 'Motorcycle',
      vehicleNo: auth.vehicleNo ?? '',
      phone: auth.phone ?? '',
      emergencyContact: auth.emergencyContact ?? '',
      emergencyContactName: auth.emergencyContactName ?? '',
      lat: joinLat,
      lng: joinLng,
      speedKmh: 0.0,
      heading: 0.0,
      batteryLevel: convoyService.currentBatteryLevel,
      isCharging: convoyService.isCharging,
      role: 'PACK',
      lastSeenEpochMs: DateTime.now().millisecondsSinceEpoch,
    );

    final joined = await convoyService.joinConvoyByCode(code: code, rider: rider);
    if (!mounted) return;
    if (joined != null) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _busy = false;
        _error = convoyService.lastError ?? 'No active ride found for this code.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final needsProfile = RideStartView._needsProfile(auth);
    final err = _error;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Enter the code shared by the person who started the ride.',
            style: AppText.body.copyWith(color: AppTheme.textSecondary),
          ),
          const SizedBox(height: Space.s16),
          if (needsProfile) ...[
            RideAlert(
              tier: AlertTier.important,
              title: 'Add your safety details to join',
              message: 'Your group needs your phone number and an emergency contact.',
              actionLabel: 'Add details',
              onAction: () => RideStartView.openProfile(context),
            ),
            const SizedBox(height: Space.s16),
          ],
          TextField(
            controller: _code,
            enabled: !_busy,
            autofocus: !needsProfile && (widget.initialCode ?? '').isEmpty,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [LengthLimitingTextInputFormatter(12)],
            textInputAction: TextInputAction.go,
            onSubmitted: (_) {
              if (!_busy && !needsProfile) _join();
            },
            style: AppText.title.copyWith(letterSpacing: 3),
            decoration: InputDecoration(
              labelText: 'Ride code',
              hintText: 'e.g. WST900',
              prefixIcon: Icon(Icons.key_rounded, color: AppTheme.textSecondary),
              border: const OutlineInputBorder(borderRadius: Radii.mdAll),
            ),
          ),
          if (err != null) ...[
            const SizedBox(height: Space.s8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline_rounded, color: StatusColors.critical, size: 20),
                const SizedBox(width: Space.s8),
                Expanded(child: Text(err, style: AppText.label.copyWith(color: StatusColors.critical))),
              ],
            ),
          ],
          const SizedBox(height: Space.s16),
          FilledButton(
            onPressed: (_busy || needsProfile) ? null : _join,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            child: _busy
                ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
                : const Text('Join'),
          ),
        ],
      ),
    );
  }
}
