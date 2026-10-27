import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../core/ui/ui.dart';
import '../../data/models/rider_model.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/intercom_service.dart';
import '../../data/services/safety_service.dart';
import '../../data/services/settings_service.dart';
import '../account/edit_profile_screen.dart';
import '../onboarding/permissions_screen.dart';
import '../rider/rider_home_screen.dart';
import '../trip_planner/trip_planner_screen.dart';
import '../widgets/pre_ride_checklist_sheet.dart';
import '../../core/config/feature_gates.dart';
import '../../data/services/plan_subscription_service.dart';
import '../subscription/plan_selector_screen.dart';
import '../garage/garage_screen.dart';

/// The Home tab when no ride is active: greeting, the "No active ride" hero
/// card with [Start Ride], the "Plan a route" / "Join Ride" tiles, the bike
/// status list, and at most one alert above it all.
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

  static bool _needsProfile(AuthService auth) =>
      !auth.isProfileComplete && !auth.isMasterAdmin;

  static bool _isOpeningProfile = false;
  static bool _isStartingRide = false;

  /// Opens the one profile editor. Returns true when the profile is complete afterwards.
  static Future<bool> openProfile(BuildContext context) async {
    if (_isOpeningProfile) return false;
    _isOpeningProfile = true;
    try {
      await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => const EditProfileScreen()),
      );
      if (!context.mounted) return false;
      return !_needsProfile(context.read<AuthService>());
    } finally {
      _isOpeningProfile = false;
    }
  }

  /// [Start Ride]: safety details first (when missing), then the trip planner.
  static Future<void> startRide(BuildContext context) async {
    if (_isStartingRide) return;
    _isStartingRide = true;
    try {
      if (_needsProfile(context.read<AuthService>())) {
        final ok = await openProfile(context);
        if (!ok || !context.mounted) return;
      }
      final planService = context.read<PlanSubscriptionService?>();
      final maxAllowed = planService?.maxConvoyMembers ?? FeatureGates.maxConvoyMembers();
      final activeConvoy = context.read<ConvoyService?>()?.activeConvoy;
      if (activeConvoy != null && activeConvoy.riders.length > maxAllowed) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: AppTheme.card,
              content: Text(
                'Active convoy exceeds your plan limit ($maxAllowed riders max). Please upgrade to continue.',
                style: TextStyle(color: AppTheme.warnText, fontWeight: FontWeight.w700),
              ),
            ),
          );
          FeatureGates.showUpgradeModal(context, Feature.unlimitedConvoyCapacity);
        }
        return;
      }
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const TripPlannerScreen()),
      );
    } finally {
      _isStartingRide = false;
    }
  }

  /// "Good morning" / "Good afternoon" / "Good evening" for [hour] (0-23).
  static String greetingFor(int hour) {
    if (hour < 12) return 'Good morning';
    if (hour < 17) return 'Good afternoon';
    return 'Good evening';
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
    final name = auth.currentUserName ?? '';

    return Scaffold(
      backgroundColor: AppTheme.bg,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: dsScreenPadding,
              physics: const BouncingScrollPhysics(),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                _Greeting(name: name),
                const SizedBox(height: 22),
                if (a != null) ...[a, const SizedBox(height: 18)],
                const _NoRideHero(),
                const SizedBox(height: 22),
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: _ActionTile(
                          icon: Icons.map_outlined,
                          title: 'Plan a route',
                          caption: 'Stops, pace and a code to share',
                          onTap: () => startRide(context),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _ActionTile(
                          icon: Icons.key_rounded,
                          title: 'Join Ride',
                          caption: 'Join with code',
                          onTap: () => showJoinRideSheet(context),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                const DsSectionHeader('Bike status'),
                const SizedBox(height: 10),
                const _BikeStatusCard(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Good afternoon" over "Ready to ride?", with the round initials button
/// that opens the Profile tab.
class _Greeting extends StatelessWidget {
  final String name;
  const _Greeting({required this.name});

  @override
  Widget build(BuildContext context) {
    final initials = initialsOf(name.isEmpty ? 'Rider' : name);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                RideStartView.greetingFor(DateTime.now().hour),
                style: AppText.label,
              ),
              const SizedBox(height: 2),
              Semantics(
                header: true,
                child: Text(
                  'Ready to ride?',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.headline.copyWith(fontSize: 26),
                ),
              ),
              const SizedBox(height: 8),
              Builder(
                builder: (ctx) {
                  final planService = ctx.watch<PlanSubscriptionService?>();
                  final tier =
                      planService?.currentTier ?? FeatureGates.activeTier;
                  final tierName = FeatureGates.tierLabel(tier).toUpperCase();
                  return GestureDetector(
                    onTap: () => Navigator.of(ctx).push(
                      MaterialPageRoute(
                        builder: (_) => const PlanSelectorScreen(),
                      ),
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.accentText.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppTheme.accentText,
                          width: 1.2,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.verified_rounded,
                            size: 14,
                            color: AppTheme.accentText,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              tierName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppTheme.accentText,
                                fontSize: 11,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 14,
                            color: AppTheme.accentText.withValues(alpha: 0.7),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Semantics(
          label: 'Profile and settings',
          button: true,
          child: Material(
            color: AppTheme.card,
            shape: CircleBorder(
              side: BorderSide(color: AppTheme.border, width: 2),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => RiderHomeScreen.selectTab(context, HomeTab.profile),
              child: SizedBox(
                width: 48,
                height: 48,
                child: Center(
                  child: Text(
                    initials,
                    maxLines: 1,
                    textScaler: TextScaler.noScaling,
                    style: TextStyle(
                      color: AppTheme.accentText,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Solid teal hero: there is no next ride planned, so it says so and
/// offers [Start Ride].
class _NoRideHero extends StatelessWidget {
  const _NoRideHero();

  @override
  Widget build(BuildContext context) {
    return DsHeroCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'NEXT RIDE',
            style: TextStyle(
              color: DsHeroCard.overline,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 4),
          Semantics(
            header: true,
            child: const Text(
              'No active ride',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                height: 1.2,
              ),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'Start a ride and share the code, or join with a code from your group.',
            style: TextStyle(
              color: DsHeroCard.secondary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 16),
          DsButton(
            label: 'Start Ride',
            icon: Icons.play_arrow_rounded,
            tone: DsButtonTone.onHero,
            fontSize: 17,
            onPressed: () => RideStartView.startRide(context),
          ),
          Builder(
            builder: (ctx) {
              final planService = ctx.watch<PlanSubscriptionService?>();
              final currentTier =
                  planService?.currentTier ?? FeatureGates.activeTier;
              final maxRiders = FeatureGates.maxConvoyMembers(currentTier);
              final tierLabel = FeatureGates.tierLabel(currentTier);
              return Padding(
                padding: const EdgeInsets.only(top: 10),
                child: GestureDetector(
                  onTap: () => Navigator.of(ctx).push(
                    MaterialPageRoute(
                      builder: (_) => const PlanSelectorScreen(),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.groups_rounded,
                        size: 14,
                        color: DsHeroCard.secondary,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'Convoy limit: Max $maxRiders bikes ($tierLabel)',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: DsHeroCard.secondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.arrow_forward_ios_rounded,
                        size: 10,
                        color: DsHeroCard.secondary,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// One of the two quick-action tiles: teal icon on top, title at the bottom.
class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String caption;
  final VoidCallback onTap;

  const _ActionTile({
    required this.icon,
    required this.title,
    required this.caption,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return DsCard(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 92),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 26, color: AppTheme.accentText),
            const SizedBox(height: 10),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.title.copyWith(fontSize: 15),
                ),
                const SizedBox(height: 2),
                Text(
                  caption,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// "BIKE STATUS": usable range, crash detection and the intercom, from the
/// services this phone has (each is optional, so the tab renders without them).
class _BikeStatusCard extends StatelessWidget {
  const _BikeStatusCard();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService?>();
    final safety = context.watch<SafetyService?>();
    final intercom = context.watch<IntercomService?>();

    String range;
    final estimate = safety?.estimatedUsableKm;
    final profile = settings?.fuelProfile;
    if (estimate != null) {
      range = '${estimate.floor()} km';
    } else if (profile != null && profile.valid) {
      range = '${profile.rangeKm.floor()} km full';
    } else {
      range = 'Not set';
    }

    final String crash = settings == null
        ? 'Not set'
        : (settings.crashDetection ? 'On' : 'Off');

    String talk;
    if (intercom == null) {
      talk = 'Off';
    } else if (intercom.isMicMuted) {
      talk = 'Muted';
    } else {
      talk = intercom.mode == IntercomMode.vox
          ? 'Voice activated'
          : 'Push to talk';
    }

    return DsCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DsListRow(
            icon: Icons.local_gas_station_rounded,
            label: 'Usable range',
            value: range,
          ),
          DsListRow(
            icon: Icons.shield_outlined,
            label: 'Crash detection',
            value: crash,
          ),
          DsListRow(
            icon: Icons.headset_mic_outlined,
            label: 'Helmet intercom',
            value: talk,
            divider: true,
          ),
          DsListRow(
            icon: Icons.two_wheeler_rounded,
            label: 'Motorcycle Garage',
            value: 'Manage & service →',
            divider: false,
            onTap: () {
              if (_isOpeningGarage) return;
              _isOpeningGarage = true;
              Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const GarageScreen()))
                  .then((_) => _isOpeningGarage = false);
            },
          ),
        ],
      ),
    );
  }
}

bool _isOpeningGarage = false;
bool _isOpeningJoinSheet = false;

/// [Join Ride] and join links: a sheet with the code field. After a
/// successful join it shows the pre-ride checklist and returns to the shell,
/// which switches to the Ride tab by itself (it listens to the active ride).
Future<void> showJoinRideSheet(
  BuildContext context, {
  String? initialCode,
}) async {
  if (_isOpeningJoinSheet) return;
  _isOpeningJoinSheet = true;
  try {
    // The join makes the ride active, so the shell swaps this Ride tab (and [context] with it)
    // for the ride map right away. The checklist is shown from the navigator, which stays.
    final nav = Navigator.of(context);
    final navContext = nav.context;
    final joined = await showAppSheet<bool>(
      context,
      title: 'Join a ride',
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxWidth: 600,
        maxHeight: MediaQuery.sizeOf(context).height * 0.88,
      ),
      builder: (_) => JoinRideSheet(initialCode: initialCode),
    );
    if (joined != true || !navContext.mounted) return;
    await PreRideChecklistSheet.show(navContext);
    if (!navContext.mounted) return;
    nav.popUntil((r) => r.isFirst);
  } finally {
    _isOpeningJoinSheet = false;
  }
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
  late final TextEditingController _code = TextEditingController(
    text: widget.initialCode ?? '',
  );
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _join() async {
    if (_busy) return;
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
      final pos =
          await Geolocator.getLastKnownPosition() ??
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

    final joined = await convoyService.joinConvoyByCode(
      code: code,
      rider: rider,
    );
    if (!mounted) return;
    if (joined != null) {
      final planService = context.read<PlanSubscriptionService?>();
      final maxAllowed = planService?.maxConvoyMembers ?? FeatureGates.maxConvoyMembers();
      final currentMembers = joined.riders.length;
      if (currentMembers > maxAllowed) {
        await convoyService.leaveActiveConvoy(rider.userId);
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = 'Convoy has $currentMembers riders. Your current plan (${FeatureGates.tierLabel(planService?.currentTier ?? FeatureGates.activeTier)}) allows up to $maxAllowed riders.';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: AppTheme.card,
            content: Text(
              'Convoy exceeds plan limit ($maxAllowed riders max). Upgrade your plan to join larger convoys.',
              style: TextStyle(color: AppTheme.warnText, fontWeight: FontWeight.w700),
            ),
          ),
        );
        FeatureGates.showUpgradeModal(context, Feature.unlimitedConvoyCapacity);
        return;
      }
      Navigator.pop(context, true);
    } else {
      setState(() {
        _busy = false;
        _error =
            convoyService.lastError ?? 'No active ride found for this code.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final needsProfile = RideStartView._needsProfile(auth);
    final err = _error;
    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Enter the code shared by the person who started the ride.',
            style: AppText.body.copyWith(color: AppTheme.text2),
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
              prefixIcon: Icon(Icons.key_rounded, color: AppTheme.accentText),
              filled: true,
              fillColor: AppTheme.card,
              enabledBorder: OutlineInputBorder(
                borderRadius: Radii.mdAll,
                borderSide: BorderSide(color: AppTheme.border, width: 2),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: Radii.mdAll,
                borderSide: BorderSide(color: AppTheme.accentText, width: 2),
              ),
              disabledBorder: OutlineInputBorder(
                borderRadius: Radii.mdAll,
                borderSide: BorderSide(color: AppTheme.border, width: 2),
              ),
              border: const OutlineInputBorder(borderRadius: Radii.mdAll),
            ),
          ),
          if (err != null) ...[
            const SizedBox(height: Space.s8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  color: AppTheme.sos,
                  size: 20,
                ),
                const SizedBox(width: Space.s8),
                Expanded(
                  child: Text(
                    err,
                    style: AppText.label.copyWith(color: AppTheme.sos),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: Space.s16),
          FilledButton(
            onPressed: (_busy || needsProfile) ? null : _join,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
            ),
            child: _busy
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  )
                : const Text('Join'),
          ),
        ],
      ),
    );
  }
}
