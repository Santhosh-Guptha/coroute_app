import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_palette.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_controller.dart';
import '../../core/ui/ui.dart';
import '../../data/local/rider_prefs_store.dart';
import '../../data/models/trip_history_model.dart';
import '../../data/services/api_client.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/clubs_service.dart';
import '../../data/services/convoy_service.dart';
import '../../data/services/crews_service.dart';
import '../../data/services/explore_service.dart';
import '../../data/services/friends_service.dart';
import '../../data/services/ride_invites_service.dart';
import '../../data/services/safety_service.dart';
import '../../data/services/settings_service.dart';
import '../../data/services/trip_storage_service.dart';
import '../../domain/explore/destinations.dart';
import '../../domain/home/home_feed.dart';
import '../../domain/home/safety_nudges.dart';
import '../../domain/score/rider_score.dart';
import '../account/edit_profile_screen.dart';
import '../diagnostics/pre_ride_phone_check_screen.dart';
import '../rider/rider_home_screen.dart';
import '../score/leaderboard_screen.dart';
import '../score/rider_score_screen.dart';
import '../shell/shell_badges.dart';
import '../social/club_widgets.dart';
import '../social/communities_rail.dart';
import '../social/crew_detail_screen.dart';
import '../social/ride_invite_screen.dart';
import '../social/user_avatar.dart';
import '../subscription/membership_status_chip.dart';
import '../trip/trip_feedback_sheet.dart';
import '../widgets/admin_warning_card.dart';
import '../widgets/emergency_sos_sheet.dart';
import '../widgets/feature_switch.dart';
import 'device_safety_facts.dart';
import 'ride_start_view.dart';

/// v3.58 Home (no active ride): greeting, header actions, one alert slot, hero carousel, a calm safety strip with
/// the Emergency button, one rotating safety nudge, riding communities, ride stats, upcoming rides and the bike
/// status. Cached data shows at once; skeletons only when nothing is cached yet.
class HomeScreen extends StatefulWidget {
  final bool showRideSaved;
  final VoidCallback? onViewSummary;
  final VoidCallback? onDismissRideSaved;

  const HomeScreen({super.key, this.showRideSaved = false, this.onViewSummary, this.onDismissRideSaved});

  /// Keys of the main sections, top to bottom (tests check them).
  static const List<String> sectionKeys = ['home_header', 'home_carousel', 'home_safety_strip', 'home_communities', 'home_stats', 'home_bike'];

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Destination>? _destinations = SwrCache.shared.peek<List<Destination>>(ExploreService.cacheKey);
  ClubsSnapshot? _clubs = ClubsService.cached();
  RiderScore? _score = SwrCache.shared.peek<RiderScore>('home:score');
  LeaderboardPosition? _rank = SwrCache.shared.peek<LeaderboardPosition>('leaderboard:me');
  DeviceSafetyFacts _facts = DeviceSafetyFacts.last ?? const DeviceSafetyFacts();
  Map<String, int> _dismissed = const {};
  (double, double)? _fix;
  bool _loadedOnce = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    final api = context.read<ApiClient?>();
    final safety = context.read<SafetyService?>();
    final f = safety?.lastFix;
    if (f != null) _fix = (f.lat, f.lng);
    final cachedDest = await ExploreService.cached();
    if (!mounted) return;
    setState(() => _destinations ??= cachedDest);
    _dismissed = await RiderPrefsStore.nudgeDismissals();
    if (!mounted) return;
    final facts = DeviceSafetyFacts.load(context);
    await Future.wait<void>([
      facts.then((v) {
        if (mounted) setState(() => _facts = v);
      }),
      if (_fix == null)
        Future<void>(() async {
          try {
            final p = await Geolocator.getLastKnownPosition();
            if (p != null && mounted) setState(() => _fix = (p.latitude, p.longitude));
          } catch (_) {}
        }),
      if (api != null) ...[
        ExploreService(api).load().then((v) {
          if (mounted) setState(() => _destinations = v);
        }).catchError((Object _) {}),
        ClubsService(api).load().then((v) {
          if (mounted) setState(() => _clubs = v);
        }).catchError((Object _) {}),
        _loadScore(api),
      ],
    ]);
    if (mounted) setState(() => _loadedOnce = true);
  }

  Future<void> _loadScore(ApiClient api) async {
    if (!api.hasToken) return;
    try {
      final s = RiderScore.fromJson(await api.get('/me/score'));
      SwrCache.shared.put<RiderScore>('home:score', s);
      if (mounted) setState(() => _score = s);
    } catch (_) {}
    try {
      final r = LeaderboardPosition.fromJson(await api.get('/me/leaderboard'));
      SwrCache.shared.put<LeaderboardPosition>('leaderboard:me', r);
      if (mounted) setState(() => _rank = r);
    } catch (_) {}
  }

  Future<void> _refresh() async {
    await Future.wait<void>([
      _load(),
      if (context.read<CrewsService?>() != null) context.read<CrewsService>().refresh(),
      if (context.read<RideInvitesService?>() != null) context.read<RideInvitesService>().refresh(autoCheck: false),
    ]);
  }

  SafetySetup _setup(AuthService auth, SettingsService? settings) => SafetySetup(
        hasEmergencyContact: (auth.emergencyContact ?? '').trim().length >= 7,
        crashDetectionOn: settings?.crashDetection ?? true,
        hasMedicalId: auth.bloodGroup.isNotEmpty || auth.medicalNotes.isNotEmpty || auth.allergies.isNotEmpty,
        nearbyDevicesOk: _facts.nearbyOk,
      );

  Future<void> _dismissNudge(SafetyNudge n, SafetySetup setup) async {
    final next = NudgeRotation.dismiss(_dismissed, n, DateTime.now().millisecondsSinceEpoch, setup);
    setState(() => _dismissed = next);
    await RiderPrefsStore.setNudgeDismissals(next);
  }

  Future<void> _actOnNudge(SafetyNudge n) async {
    switch (n) {
      case SafetyNudge.emergencyContact:
      case SafetyNudge.medicalId:
        await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const EditProfileScreen()));
      case SafetyNudge.crashDetection:
        await context.read<SettingsService?>()?.setCrashDetection(true);
        if (mounted) showAppToast(context, 'Crash detection is on.');
      case SafetyNudge.nearbyDevices:
        final ok = await DeviceSafetyFacts.requestNearby();
        if (!mounted) return;
        setState(() => _facts = DeviceSafetyFacts(nearbyOk: ok, preRideDue: _facts.preRideDue));
    }
  }

  void _openEmergency() {
    final f = context.read<SafetyService?>()?.lastFix;
    EmergencySosSheet.show(context, lat: f?.lat ?? 0, lng: f?.lng ?? 0);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final convoys = context.watch<ConvoyService?>();
    final settings = context.watch<SettingsService?>();
    final trips = context.watch<TripStorageService?>()?.trips ?? const <TripHistoryModel>[];
    final alert = RideStartView.alertFor(context,
        auth: auth, convoys: convoys, showRideSaved: widget.showRideSaved, onViewSummary: widget.onViewSummary, onDismissRideSaved: widget.onDismissRideSaved);
    final setup = _setup(auth, settings);
    final nudge = NudgeRotation.pick(setup, dismissedAt: _dismissed, nowMs: DateTime.now().millisecondsSinceEpoch, riding: convoys?.activeGroupId != null);
    final ranked = _destinations == null ? const <RankedDestination>[] : ExploreRanking.rank(_destinations!, lat: _fix?.$1, lng: _fix?.$2);
    final last = trips.isEmpty ? null : trips.reduce((a, b) => a.startTimeEpochMs >= b.startTimeEpochMs ? a : b);
    final cards = HomeFeed.heroCards(hasLastRide: last != null, safetyCheckDue: _facts.preRideDue);

    return Scaffold(
      backgroundColor: AppTheme.bg,
      body: SafeArea(
        bottom: false,
        child: ContentWidth(
          maxWidth: 680,
          child: AppRefresh(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 96),
              physics: AppScrollBehavior.physics,
              children: [
                _HomeHeader(key: Key(HomeScreen.sectionKeys[0]), auth: auth),
                const SizedBox(height: Space.s12),
                if (alert != null) ...[alert, const SizedBox(height: Space.s12)],
                const AdminWarningCard(),
                _HeroCarousel(
                  key: Key(HomeScreen.sectionKeys[1]),
                  cards: cards,
                  nearest: ranked.isEmpty ? null : ranked.first,
                  lastRide: last,
                ),
                const SizedBox(height: Space.s12),
                _SafetyStrip(key: Key(HomeScreen.sectionKeys[2]), setup: setup, onEmergency: _openEmergency),
                if (nudge != null) ...[
                  const SizedBox(height: Space.s12),
                  _NudgeStrip(nudge: nudge, onAct: () => _actOnNudge(nudge), onDismiss: () => _dismissNudge(nudge, setup)),
                ],
                const OfflineSoloCard(showEntry: false),
                const SizedBox(height: Space.s24),
                CommunitiesRail(key: Key(HomeScreen.sectionKeys[3]), clubs: _clubs, loading: !_loadedOnce && _clubs == null, onClubsChanged: _load, onSeeAll: () => RiderHomeScreen.selectTab(context, HomeTab.people)),
                const SizedBox(height: Space.s24),
                _RideStats(key: Key(HomeScreen.sectionKeys[4]), trips: trips, score: _score, rank: _rank),
                _Upcoming(clubs: _clubs),
                const SizedBox(height: Space.s24),
                SectionTitle('Bike status', key: Key(HomeScreen.sectionKeys[5])),
                const SizedBox(height: Space.s8),
                const BikeStatusCard(),
                // After a ride the cockpit did not close itself: asks once for the post-trip review. Renders nothing.
                const PendingTripReviewCheck(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------- header

class _HomeHeader extends StatelessWidget {
  final AuthService auth;
  const _HomeHeader({super.key, required this.auth});

  @override
  Widget build(BuildContext context) {
    final full = (auth.currentUserName ?? '').trim();
    final first = full.isEmpty ? 'Rider' : full.split(RegExp(r'\s+')).first;
    final social = context.watch<FriendsService?>();
    final photosOn = context.featureOn(FriendsService.photosFlag);
    final theme = Provider.of<ThemeController?>(context);
    final alerts = ShellBadges.alerts(context);
    final dark = !AppTheme.isLight;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(RideStartView.greetingFor(DateTime.now().hour), style: AppText.label),
              const SizedBox(height: 2),
              Semantics(
                header: true,
                child: Text(first, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.headline.copyWith(fontSize: 26, color: AppTheme.accentText)),
              ),
              const SizedBox(height: 6),
              const MembershipStatusChip(),
            ],
          ),
        ),
        const SizedBox(width: Space.s8),
        Badge(
          isLabelVisible: alerts > 0,
          label: Text(alerts > 9 ? '9+' : '$alerts'),
          child: DsRoundButton(
            key: const Key('home_alerts'),
            icon: Icons.notifications_none_rounded,
            label: alerts > 0 ? 'Alerts, $alerts need attention' : 'Alerts',
            size: 48,
            onTap: () => RiderHomeScreen.selectTab(context, HomeTab.alerts),
          ),
        ),
        if (theme != null) ...[
          const SizedBox(width: Space.s8),
          DsRoundButton(
            key: const Key('home_theme'),
            icon: dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
            label: dark ? 'Switch to light theme' : 'Switch to dark theme',
            size: 48,
            onTap: () {
              AppHaptics.selection();
              theme.setPreference(dark ? ThemePreference.light : ThemePreference.dark);
            },
          ),
        ],
        const SizedBox(width: Space.s8),
        Semantics(
          button: true,
          label: 'Profile and settings',
          excludeSemantics: true,
          child: Pressable(
            key: const Key('home_avatar'),
            onTap: () => RiderHomeScreen.selectTab(context, HomeTab.profile),
            child: UserAvatar(label: full.isEmpty ? 'Rider' : full, avatarUrl: photosOn ? social?.profile?.avatarUrl : null, size: 48, filled: true),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------- carousel

class _HeroCarousel extends StatefulWidget {
  final List<HeroCard> cards;
  final RankedDestination? nearest;
  final TripHistoryModel? lastRide;
  const _HeroCarousel({super.key, required this.cards, this.nearest, this.lastRide});

  @override
  State<_HeroCarousel> createState() => _HeroCarouselState();
}

class _HeroCarouselState extends State<_HeroCarousel> {
  final PageController _page = PageController(viewportFraction: 0.94);
  Timer? _timer;
  int _index = 0;
  bool _holding = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _schedule();
  }

  @override
  void didUpdateWidget(covariant _HeroCarousel old) {
    super.didUpdateWidget(old);
    if (old.cards.length != widget.cards.length) {
      _index = _index.clamp(0, widget.cards.length - 1);
      _schedule();
    }
  }

  void _schedule() {
    _timer?.cancel();
    final reduced = AppMotion.reducedOf(context);
    if (!CarouselPolicy.autoAdvance(reducedMotion: reduced, cards: widget.cards.length, userHolding: _holding)) return;
    _timer = Timer.periodic(CarouselPolicy.interval, (_) {
      if (!mounted || !_page.hasClients || _holding) return;
      final next = CarouselPolicy.next(_index, widget.cards.length);
      _page.animateToPage(next, duration: Motion.screen, curve: Motion.curve);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final double height = 186 + (scale > 1 ? (scale - 1) * 60 : 0);
    return Column(
      children: [
        Listener(
          onPointerDown: (_) {
            _holding = true;
            _timer?.cancel();
          },
          onPointerUp: (_) {
            _holding = false;
            _schedule();
          },
          onPointerCancel: (_) {
            _holding = false;
            _schedule();
          },
          child: SizedBox(
            height: height,
            child: PageView.builder(
              controller: _page,
              padEnds: false,
              itemCount: widget.cards.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (_, i) => Padding(padding: const EdgeInsets.only(right: 10), child: _heroCard(context, widget.cards[i])),
            ),
          ),
        ),
        const SizedBox(height: Space.s12),
        CarouselDots(count: widget.cards.length, index: _index),
      ],
    );
  }

  Widget _heroCard(BuildContext context, HeroCard c) {
    switch (c) {
      case HeroCard.ridesNearYou:
        final n = widget.nearest;
        final line = n == null
            ? 'Breakfast runs, ghats and weekend trips near you'
            : 'Nearest: ${n.destination.name}${n.roadKm == null ? '' : ' · ${ExploreRanking.kmLabel(n.roadKm)}'}';
        return _HeroTile(
          key: const Key('hero_rides_near_you'),
          seed: n?.destination.name ?? 'rides',
          title: 'Rides near you',
          line: line,
          button: 'Find rides',
          icon: Icons.explore_rounded,
          onTap: () => RiderHomeScreen.selectTab(context, HomeTab.explore),
        );
      case HeroCard.groupRide:
        return _HeroTile(
          key: const Key('hero_group_ride'),
          seed: 'group',
          title: 'Start a group ride',
          line: 'Live map, helmet intercom and SOS for everyone',
          button: 'Start ride',
          icon: Icons.play_arrow_rounded,
          onTap: () => RideStartView.startRide(context),
        );
      case HeroCard.lastRide:
        final t = widget.lastRide!;
        final km = t.totalDistanceKm;
        final name = t.tripName.trim().isNotEmpty ? t.tripName.trim() : (t.destinationName.trim().isNotEmpty ? t.destinationName.trim() : 'Your last ride');
        return _HeroTile(
          key: const Key('hero_last_ride'),
          seed: name,
          title: name,
          line: '${km.toStringAsFixed(km < 10 ? 1 : 0)} km · ${_minutes(t.durationMinutes)} · top ${t.topSpeedKmh.round()} km/h',
          button: 'Trip report',
          icon: Icons.insights_rounded,
          overline: 'Your last ride',
          onTap: () => RiderHomeScreen.selectTab(context, HomeTab.trips),
        );
      case HeroCard.safetyCheck:
        return _HeroTile(
          key: const Key('hero_safety_check'),
          seed: 'safety',
          title: 'Safety check before you ride',
          line: 'GPS, motion sensors, alarms and battery in about 8 seconds',
          button: 'Check my phone',
          icon: Icons.health_and_safety_rounded,
          night: true,
          onTap: () => PreRidePhoneCheckScreen.open(context),
        );
    }
  }

  static String _minutes(int m) => m < 60 ? '$m min' : '${m ~/ 60} h ${m % 60} min';
}

class _HeroTile extends StatelessWidget {
  final String seed;
  final String title;
  final String line;
  final String button;
  final IconData icon;
  final String? overline;
  final bool night;
  final VoidCallback onTap;
  const _HeroTile({super.key, required this.seed, required this.title, required this.line, required this.button, required this.icon, required this.onTap, this.overline, this.night = false});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: '$title. $line',
      child: ClipRRect(
        borderRadius: Radii.xlAll,
        child: Stack(
          fit: StackFit.expand,
          children: [
            PlaceArt(seed: seed, night: night, scrim: true, borderRadius: Radii.xlAll),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (overline != null) Text(overline!, style: const TextStyle(color: DsHeroCard.overline, fontSize: 13, fontWeight: FontWeight.w500)),
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600, height: 1.25)),
                  const SizedBox(height: 4),
                  Text(line, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: DsHeroCard.secondary, fontSize: 14, height: 1.3)),
                  const Spacer(),
                  ExcludeSemantics(
                    excluding: false,
                    child: Material(
                      color: Colors.white,
                      shape: const StadiumBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () {
                          AppHaptics.light();
                          onTap();
                        },
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 18),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(icon, size: 20, color: AppPalette.light.text),
                                  const SizedBox(width: 8),
                                  Text(button, style: TextStyle(color: AppPalette.light.text, fontSize: 15, fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------- safety

class _SafetyStrip extends StatelessWidget {
  final SafetySetup setup;
  final VoidCallback onEmergency;
  const _SafetyStrip({super.key, required this.setup, required this.onEmergency});

  @override
  Widget build(BuildContext context) {
    final safety = context.watch<SafetyService?>();
    final ok = AppTheme.success;
    final warn = AppTheme.warnText;
    Widget pill(bool good, IconData icon, String text) => InfoPill(icon: good ? icon : Icons.error_outline_rounded, text: text, color: good ? ok : warn);
    return DsCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.shield_outlined, size: 20, color: AppTheme.accentText),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Ride safety',
                  style: AppText.title.copyWith(fontSize: 15),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Semantics(
                button: true,
                label: 'Emergency: call your contact or 112, share your location',
                excludeSemantics: true,
                child: OutlinedButton.icon(
                  key: const Key('home_emergency'),
                  onPressed: () {
                    AppHaptics.medium();
                    onEmergency();
                  },
                  icon: Icon(Icons.sos_rounded, color: AppTheme.sos, size: 20),
                  label: Text('Emergency', style: TextStyle(color: AppTheme.sos, fontWeight: FontWeight.w700)),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    side: BorderSide(color: AppTheme.sos, width: 1.5),
                    shape: const StadiumBorder(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              pill(setup.crashDetectionOn, Icons.car_crash_outlined, setup.crashDetectionOn ? 'Crash detection on' : 'Crash detection off'),
              pill(setup.hasEmergencyContact, Icons.contact_phone_outlined, setup.hasEmergencyContact ? 'Emergency contact set' : 'No emergency contact'),
              pill(safety != null, Icons.sms_outlined, 'SOS works without data'),
              if (setup.nearbyDevicesOk) pill(true, Icons.bluetooth_searching_rounded, 'Offline link ready'),
            ],
          ),
        ],
      ),
    );
  }
}

class _NudgeStrip extends StatelessWidget {
  final SafetyNudge nudge;
  final VoidCallback onAct;
  final VoidCallback onDismiss;
  const _NudgeStrip({required this.nudge, required this.onAct, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: AppMotion.durationOf(context, Motion.tab),
      child: Container(
        key: ValueKey(nudge),
        padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
        decoration: BoxDecoration(color: AppTheme.warnTint, borderRadius: Radii.lgAll, border: Border.all(color: AppTheme.warnBorder)),
        child: Row(
          children: [
            Icon(Icons.health_and_safety_outlined, color: AppTheme.warnText, size: 22),
            const SizedBox(width: 10),
            Expanded(child: Text(nudge.line, key: const Key('home_nudge'), style: AppText.body.copyWith(color: AppTheme.text, fontSize: 14), maxLines: 3, overflow: TextOverflow.ellipsis)),
            TextButton(
              onPressed: onAct,
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              child: Text(nudge.action, style: TextStyle(color: AppTheme.warnText, fontWeight: FontWeight.w700)),
            ),
            IconButton(
              tooltip: 'Not now',
              onPressed: onDismiss,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: Icon(Icons.close_rounded, color: AppTheme.text2, size: 20),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------- stats

class _RideStats extends StatelessWidget {
  final List<TripHistoryModel> trips;
  final RiderScore? score;
  final LeaderboardPosition? rank;
  const _RideStats({super.key, required this.trips, this.score, this.rank});

  @override
  Widget build(BuildContext context) {
    final a = HomeAnalytics.of(trips);
    final scoreOn = context.featureOn('riderScore');
    final boardOn = context.featureOn('leaderboard');
    final r = rank?.rank(LeaderboardBoard.topScore);
    final km = a.totalDistanceKm;
    Widget cell(String value, String label, {VoidCallback? onTap}) => Expanded(
          child: Semantics(
            button: onTap != null,
            label: '$label: $value',
            excludeSemantics: true,
            child: InkWell(
              onTap: onTap,
              borderRadius: Radii.mdAll,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  children: [
                    FittedBox(fit: BoxFit.scaleDown, child: Text(value, style: AppText.metric.copyWith(fontSize: 22))),
                    const SizedBox(height: 2),
                    Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
                  ],
                ),
              ),
            ),
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle('Your ride stats', action: scoreOn ? 'Full view' : null, onAction: scoreOn ? () => RiderScoreScreen.open(context) : null),
        const SizedBox(height: Space.s8),
        DsCard(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Column(
            children: [
              Row(
                children: [
                  cell(km >= 1000 ? '${(km / 1000).toStringAsFixed(1)}k' : km.toStringAsFixed(0), 'km ridden'),
                  cell('${a.rides}', a.rides == 1 ? 'ride' : 'rides'),
                  if (scoreOn) cell(score?.ready == true ? '${score!.score}' : '–', 'rider score', onTap: () => RiderScoreScreen.open(context)),
                ],
              ),
              if (boardOn) ...[
                Divider(height: 1, color: AppTheme.border),
                InkWell(
                  key: const Key('home_leaderboard'),
                  onTap: () => LeaderboardScreen.open(context),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 52),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      children: [
                        Icon(Icons.emoji_events_outlined, color: AppTheme.accent, size: 22),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Leaderboard',
                            style: AppText.body.copyWith(fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            r != null && (rank?.onLeaderboard ?? false) ? 'All India · #$r' : 'See where you stand',
                            style: AppText.label,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.end,
                          ),
                        ),
                        Icon(Icons.chevron_right_rounded, color: AppTheme.muted),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (scoreOn && score != null && !score!.ready && (score!.progressLine ?? '').isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(score!.progressLine!, style: AppText.caption),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------- upcoming

class _Upcoming extends StatelessWidget {
  final ClubsSnapshot? clubs;
  const _Upcoming({required this.clubs});

  @override
  Widget build(BuildContext context) {
    final invites = context.watch<RideInvitesService?>()?.pending ?? const [];
    final crews = context.watch<CrewsService?>()?.crews ?? const <CrewSummary>[];
    final now = DateTime.now();
    final items = UpcomingFeed.merge([
      for (final i in invites)
        UpcomingItem(kind: UpcomingKind.rideInvite, id: i.inviteId, title: i.rideName.isNotEmpty ? i.rideName : 'Ride with ${i.crewName}', subtitle: '${i.crewName} · @${i.hostUsername} invited you', atMs: i.expiresAt),
      for (final c in clubs?.clubs ?? const <ClubSummary>[])
        for (final r in c.upcoming) UpcomingItem(kind: UpcomingKind.clubRide, id: c.operatorId, title: r.title, subtitle: [c.name, if (r.meetName.isNotEmpty) r.meetName].join(' · '), atMs: r.startsAt),
      for (final c in crews)
        if (c.openPolls > 0) UpcomingItem(kind: UpcomingKind.crewPoll, id: c.crewId, title: '${c.name}: ${c.openPolls == 1 ? 'a poll is open' : '${c.openPolls} polls are open'}', subtitle: c.pendingVotes > 0 ? 'Your vote is waiting' : 'Plan the next ride together', atMs: c.nextPollClosesAt),
    ], nowMs: now.millisecondsSinceEpoch);
    if (items.isEmpty) return const SizedBox.shrink();
    IconData iconOf(UpcomingKind k) => switch (k) { UpcomingKind.rideInvite => Icons.mail_outline_rounded, UpcomingKind.clubRide => Icons.event_rounded, UpcomingKind.crewPoll => Icons.how_to_vote_outlined };
    return Padding(
      padding: const EdgeInsets.only(top: Space.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionTitle('Upcoming'),
          const SizedBox(height: Space.s8),
          DsCard(
            key: const Key('home_upcoming'),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: Column(
              children: [
                for (var k = 0; k < items.length; k++)
                  DsListRow(
                    icon: iconOf(items[k].kind),
                    label: items[k].title,
                    value: UpcomingFeed.whenLabel(items[k].atMs, now: now),
                    divider: k < items.length - 1,
                    onTap: () {
                      final it = items[k];
                      switch (it.kind) {
                        case UpcomingKind.rideInvite:
                          RideInviteScreen.open(context, it.id);
                        case UpcomingKind.clubRide:
                          final club = clubs?.clubs.where((c) => c.operatorId == it.id).firstOrNull;
                          if (club != null) ClubSheet.show(context, club);
                        case UpcomingKind.crewPoll:
                          CrewDetailScreen.open(context, it.id);
                      }
                    },
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
