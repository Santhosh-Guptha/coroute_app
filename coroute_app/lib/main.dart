import 'data/services/ride_essentials_coordinator.dart';
import 'data/services/route_essentials_service.dart';
import 'data/services/fuel_sharing_binding.dart';
import 'data/services/fuel_settings_binding.dart';
import 'data/services/garage_binding.dart';
import 'data/services/garage_service.dart';
import 'data/services/phone_call_service.dart';
import 'dart:async';
import 'dart:isolate';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'core/native_licenses.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:url_launcher/url_launcher.dart';
import 'core/constants/app_constants.dart';
import 'data/local/review_prompt_store.dart';
import 'core/l10n/l10n.dart';
import 'core/constants/navigation_constants.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'core/ui/ui.dart';
import 'data/services/alert_service.dart';
import 'data/services/api_client.dart';
import 'data/services/feature_flags_service.dart';
import 'data/services/admin_warnings_service.dart';
import 'data/services/friends_service.dart'; // 3.55 usernames, friends, profile pictures
import 'data/services/crews_service.dart'; // 3.55 crews and crew polls
import 'data/services/rider_score_service.dart'; // 3.55 rider score sync at ride end
import 'presentation/social/friend_notice_host.dart'; // 3.55 friend request notices
import 'presentation/social/ride_invite_screen.dart'; // 3.55 crew ride invites
import 'domain/social/username_rules.dart' show InviteCodes;
import 'data/services/auth_service.dart';
import 'data/services/app_lock_service.dart';
import 'domain/auth/account_flows.dart';
import 'presentation/auth/mfa_prompt_dialog.dart';
import 'presentation/security/app_lock_gate.dart';
import 'presentation/security/locked_cockpit_gate.dart'; // cockpit on the lock screen while riding
import 'data/services/lock_screen_cockpit_service.dart';
import 'presentation/safety/sos_hold_screen.dart';
import 'presentation/widgets/emergency_sos_sheet.dart';
import 'data/services/background_service.dart';
import 'data/services/alarm_notifier.dart'; // 3.55 siren lock-screen heads-up
import 'data/services/p2p_mesh_service.dart';
import 'data/services/offline_link/offline_link_service.dart'; // Round 10 offline link
import 'data/services/convoy_service.dart';
import 'data/services/geo_service.dart';
import 'data/services/intercom_service.dart';
import 'data/services/speed_audio_service.dart';
import 'data/services/meta_service.dart';
import 'data/services/app_version_service.dart';
import 'data/services/device_diagnostic_service.dart';
import 'data/services/membership_service.dart';
import 'data/local/ride_stats_store.dart';
import 'data/local/sqflite_track_queue.dart';
import 'data/services/realtime_service.dart';
import 'data/services/ride_mic_hub.dart'; // 3.55 sound awareness (mic)
import 'data/services/siren_acoustic_detector.dart'; // 3.55 sound awareness (mic)
import 'data/services/audio_priority_manager.dart'; // 3.55 sound awareness (mic)
import 'data/services/ride_notification_service.dart';
import 'data/services/medical_id_lock_sync.dart';
import 'data/services/safety_native.dart';
import 'data/services/safety_service.dart';
import 'data/services/session_guard.dart'; // 3.57 never signed out mid-ride
import 'domain/auth/session_policy.dart';
import 'data/services/solo_guardian_service.dart';
import 'data/services/sos_battery_reserve.dart';
import 'data/services/settings_service.dart';
import 'data/services/offline_map_retention_service.dart';
import 'data/services/tile_cache_service.dart';
import 'data/services/timeline_service.dart';
import 'data/services/public_ride_service.dart';
import 'data/services/push_service.dart'; // 3.55 push notifications
import 'data/services/engagement_service.dart'; // 3.55 ratings & reviews
import 'data/services/ride_invites_service.dart'; // 3.55 crew ride invites
import 'data/services/track_recorder.dart';
import 'data/services/track_uploader.dart';
import 'data/services/trip_storage_service.dart';
import 'data/services/nav_voice.dart';
import 'data/services/voice_service.dart';
import 'domain/audio/audio_diag_log.dart'; // 3.55 audio diagnostics (no personal data)
import 'domain/diag/diag_log.dart'; // 3.55 persistent diagnostics log (no personal data)
import 'domain/diag/diag_redact.dart';
import 'data/services/diag_log_service.dart';
import 'presentation/settings/diag_prompt_host.dart';
import 'data/services/weather_service.dart';
import 'data/services/permission_revocation_safety_service.dart';
import 'data/services/place_review_service.dart';
import 'data/services/group_safety_service.dart';
import 'data/services/map_places_service.dart';
import 'domain/notify/notification_snapshot.dart';
import 'presentation/auth/access_gate_screen.dart';
import 'presentation/trip_planner/share_in_opener.dart'; // 3.56 Share to CoRoute
import 'presentation/ride/emergency_guidance.dart';
import 'presentation/safety/crash_alarm_host.dart';
// ==== Round 10 rescue beacon (docs/features_355/rescue_beacon.md)
import 'data/services/rescue_beacon_service.dart';
import 'data/services/rescue_bindings.dart';
import 'data/services/rescue_finder_service.dart';
import 'presentation/rescue/rescue_beacon_host.dart';
import 'presentation/splash/splash_screen.dart';
import 'presentation/widgets/push_router_host.dart'; // 3.55 push notifications
import 'presentation/widgets/startup_warmup.dart'; // round 7 idle precache
import 'presentation/settings/intel_prompt_host.dart';
import 'data/services/private_places_store.dart';

/// Lets services navigate (sign-out on session expiry, deep links) without a BuildContext.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// 3.55: everything runs in a guarded zone so uncaught errors reach the diagnostics log
/// (docs/features_355/diagnostics_logs.md). The binding is initialised inside the same zone.
void main() {
  registerNativeLicenses(); // round 8: RNNoise attribution in the licences page
  runZonedGuarded<Future<void>>(_main, (error, stack) {
    DiagLog.caught(DiagCat.errors, 'uncaught_zone', error, stack);
    // Still printed to the console / logcat as before the guarded zone.
    debugPrint('Uncaught error: $error\n$stack');
  });
}

/// Flutter framework errors, uncaught platform / async errors and isolate errors go to the
/// diagnostics log; the previous behaviour (console output, red screen in debug) is kept.
void _installErrorCapture() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    DiagLog.caught(DiagCat.errors, 'flutter_error', details.exception, details.stack, {'lib': details.library});
    if (previous != null) {
      previous(details);
    } else {
      FlutterError.presentError(details);
    }
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    DiagLog.caught(DiagCat.errors, 'uncaught_async', error, stack);
    debugPrint('Uncaught error: $error\n$stack');
    return true;
  };
  try {
    Isolate.current.addErrorListener(RawReceivePort((Object? pair) {
      if (pair is List && pair.isNotEmpty) {
        DiagLog.error(DiagCat.errors, 'isolate_error', {'what': pair.first, 'stack': DiagRedact.stackTop(pair.length > 1 ? pair[1] : null)});
      }
    }).sendPort);
  } catch (_) {}
}

Future<void> _main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _installErrorCapture();
  // 3.55: a tapped RIDE_INVITE push opens the invitation screen (set before any push can arrive).
  PushRouterHost.openRideInvite = RideInviteScreen.open;
  tz_data.initializeTimeZones();
  BackgroundService.initCommunicationPort();
  // ==== Round 7 start-up (UX/perf) BEGIN: the independent reads below used to run one after the other;
  // they now run side by side and ALL still finish before runApp, so everything that was ready at the
  // first frame before is ready now (theme, settings, sound settings, tile cache, package info).
  // Nothing safety-related is deferred or reordered: the providers are created in the same order.
  // Portrait + landscape are both supported; layouts adapt to width.
  final orientations = SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  // 3.55 persistent diagnostics log: files in <filesDir>/diag, native crashes merged (not awaited:
  // entries logged before it is ready wait in memory). Starts as soon as the build number is known.
  final packageInfo = MetaService.readPackageInfo().then((_) {
    DiagLogService.instance.init(build: '${MetaService.currentVersion}+${MetaService.currentBuild}').ignore();
  });
  // Light or dark is decided before the first frame, so there is no flash.
  final theme = ThemeController();
  final themeLoaded = theme.load();
  // Another rider's SOS over the lock screen (Android full-screen intent, heads-up fallback).
  AlertService.urgentPoster = RideNotificationChannel.postUrgent;
  // The phone's language decides the safety texts when the setting is "System language".
  L10n.systemLanguage = WidgetsBinding.instance.platformDispatcher.locale.languageCode;
  // Data saver is known before the first frame, so the first ride already uses it.
  final settings = SettingsService();
  final settingsLoaded = settings.load().then((_) => settings.loadSoundSettings()); // 3.55 sound awareness (mic): siren / voice cleanup settings
  // Map tiles saved on the phone (3.16): best effort; without it maps use the network.
  final tilesOpened = () async {
    try {
      final dir = await SafetyNative.cacheDir();
      if (dir != null) TileCache.instance = await TileCache.open('$dir/tiles');
    } catch (_) {
      TileCache.instance = null;
    }
  }();
  await Future.wait<void>([orientations, packageInfo, themeLoaded, settingsLoaded, tilesOpened]);
  // Battery saver reduces motion app-wide (no shimmer loop, no parallax): lib/core/ui/app_motion.dart.
  AppMotion.batterySaver.value = settings.batterySaver;
  settings.addListener(() => AppMotion.batterySaver.value = settings.batterySaver);
  // ==== Round 7 start-up (UX/perf) END
  // Saved trip maps past their time (7 days after the trip) or over 300 MB go; the rest are kept.
  OfflineMapRetentionService.sweep().ignore();
  // Rider-only ride numbers (hard stops) older than 90 days go; nothing else to maintain.
  RideStatsStore.prune().ignore();
  // Install time for the store-rating prompt (never in the first days after install).
  ReviewPromptStore.markFirstSeen().ignore();
  SystemChrome.setSystemUIOverlayStyle(AppTheme.overlayStyle);
  runApp(CoRouteApp(theme: theme, settings: settings));
}

class CoRouteApp extends StatelessWidget {
  final ThemeController theme;
  final SettingsService? settings;
  const CoRouteApp({super.key, required this.theme, this.settings});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<ThemeController>.value(value: theme),
        ChangeNotifierProvider<SettingsService>(
          create: (_) => settings ?? (SettingsService()..load()),
        ),
        ChangeNotifierProvider(
          create: (_) {
            final api = ApiClient();
            // Round 4: an admin call answered MFA_REQUIRED: ask for the 2-step code (step-up), then the call repeats once.
            api.onMfaRequired = (body) async {
              final ctx = appNavigatorKey.currentContext;
              if (ctx == null) return false;
              Future<String?> submit({
                String? code,
                String? recoveryCode,
                String? emailCode,
              }) async {
                try {
                  await api.post('/auth/mfa/step-up', {
                    'code': ?code,
                    'recoveryCode': ?recoveryCode,
                    'emailCode': ?emailCode,
                  });
                  return null;
                } on ApiException catch (e) {
                  return e.message;
                } catch (_) {
                  return 'Could not check the code. Try again.';
                }
              }

              Future<String?> sendEmail() async {
                try {
                  await api.post('/auth/mfa/step-up/email-code', const {});
                  return null;
                } on ApiException catch (e) {
                  return e.message;
                }
              }

              return MfaPromptDialog.show(
                ctx,
                challenge: MfaChallenge.fromBody(body),
                submit: submit,
                sendEmailCode: sendEmail,
              );
            };
            return api;
          },
        ),
        // Round 4: "Lock CoRoute with fingerprint or screen lock" (off by default; never during a ride or SOS).
        // Started by _SessionBinder once the saved session is read (a cold start locks only a signed-in phone).
        ChangeNotifierProvider<AppLockService>(
          lazy: false,
          create: (_) => AppLockService(),
        ),
        // Cockpit on the lock screen while riding (docs/features_355/lock_screen_cockpit.md): wired and started by
        // _SessionBinder (sign-in, the setting, the ride state). Never over the keyguard without a ride.
        ChangeNotifierProvider<LockScreenCockpitService>(
          lazy: false,
          create: (_) => LockScreenCockpitService(),
        ),
        // 3.55 diagnostics log (Settings › More › Diagnostics, the post-ride safety prompt).
        ChangeNotifierProvider<DiagLogService>.value(value: DiagLogService.instance),
        ChangeNotifierProvider<DeviceDiagnosticService>(create: (ctx) => DeviceDiagnosticService(apiClient: ctx.read<ApiClient>())..loadCachedReport()),
        // Weather along the route (3.16): two small requests per ride through the gateway.
        ChangeNotifierProvider<WeatherService>(create: (ctx) => WeatherService(ctx.read<ApiClient>(), ctx.read<SettingsService>())),
        // Route map tiles saved before the ride (3.16): one bounded job, on Wi-Fi or by a tap.
        ChangeNotifierProvider<TilePrefetcher>(create: (_) => TilePrefetcher(TileCache.instance)),
        ChangeNotifierProvider(create: (ctx) {
          final api = ctx.read<ApiClient>();
          final rt = RealtimeService();
          // A refreshed session token is used for the next reconnect.
          api.addListener(() => rt.updateToken(api.token));
          // The gateway answered over HTTP, or the app is back in front: a socket waiting out
          // its backoff reconnects now (no-op when connected or already connecting).
          api.onServerReached = rt.retryNow;
          AppLifecycleListener(onResume: rt.retryNow);
          return rt;
        }),
        // 3.55 admin feature switches: saved copy, GET /features, socket FEATURE_FLAGS pushes.
        // Not lazy, so a switch applies even before any screen asks for it.
        ChangeNotifierProvider<FeatureFlagsService>(lazy: false,
          create: (ctx) => FeatureFlagsService(ctx.read<ApiClient>(), realtime: ctx.read<RealtimeService>())),
        // 3.55 platform: moderator warnings on Home (GET /me/warnings + socket push; switch adminWarnings).
        ChangeNotifierProvider<AdminWarningsService>(lazy: false,
          create: (ctx) => AdminWarningsService(ctx.read<ApiClient>(), realtime: ctx.read<RealtimeService>())),
        ChangeNotifierProvider<FriendsService>(lazy: false,
          create: (ctx) => FriendsService(ctx.read<ApiClient>(), realtime: ctx.read<RealtimeService>())),
        // 3.55 crews and crew polls (GET /crews + socket pushes; switches crews / crewPolls).
        ChangeNotifierProvider<CrewsService>(lazy: false,
          create: (ctx) => CrewsService(ctx.read<ApiClient>(), realtime: ctx.read<RealtimeService>())),
        // 3.55 "Start a ride with this crew": my ride invitations + socket RIDE_INVITE (switch crewRides).
        ChangeNotifierProvider<RideInvitesService>(lazy: false,
          create: (ctx) => RideInvitesService(ctx.read<ApiClient>(), realtime: ctx.read<RealtimeService>())),
        // 3.55 push notifications (FCM via the native coroute/push channel): token registration after
        // sign-in, removal on sign-out, tapped notifications (routed by PushRouterHost).
        ChangeNotifierProvider<PushService>(lazy: false, create: (ctx) => PushService(ctx.read<ApiClient>())..start()),
        // 3.55 ratings & reviews: admin engagement templates (cached), "Rate CoRoute" state, feedback.
        ChangeNotifierProvider<EngagementService>(lazy: false, create: (ctx) => EngagementService(ctx.read<ApiClient>())),
        ChangeNotifierProvider(create: (ctx) {
          final auth = AuthService(ctx.read<ApiClient>());
          ctx.read<RealtimeService>().onAuthRejected = auth.revalidate;
          return auth;
        }),
        Provider<FuelSettingsBinding>(lazy: false,
          create: (ctx) => FuelSettingsBinding(ctx.read<AuthService>(), ctx.read<SettingsService>()),
          dispose: (_, binding) => binding.dispose()),
        ChangeNotifierProvider(create: (ctx) => MetaService(ctx.read<ApiClient>())..load()),
        ChangeNotifierProvider(create: (ctx) => AppVersionService(ctx.read<MetaService>())),
        ChangeNotifierProvider(create: (ctx) {
          // The membership is the single source of the rider's plan; sign-out forgets it.
          final ms = MembershipService(ctx.read<ApiClient>())..fetchMyMembership()..fetchCatalog();
          ctx.read<AuthService>().onSessionCleared = () => ms.clearLocal().ignore();
          return ms;
        }),
        ChangeNotifierProvider(create: (ctx) => TripStorageService(ctx.read<ApiClient>())),
        ChangeNotifierProvider(create: (ctx) => TimelineService(ctx.read<ApiClient>(), ctx.read<RealtimeService>())),
        // Public ride, safe contact and road warnings (every plan; gateway feature pubride1). Road
        // warnings speak in the important tier and stay silent while my group has an emergency open.
        ChangeNotifierProvider<PublicRideService>(create: (ctx) {
          final pr = PublicRideService(ctx.read<RealtimeService>());
          pr.speaker = (line, key) => ctx.read<VoiceService>().speak(line, priority: VoicePriority.important, key: key).ignore();
          pr.emergencyActive = () => ctx.read<ConvoyService>().activeConvoy?.activeAlerts.any((a) => !a.resolved) ?? false;
          // 3.55 admin feature switch: public ride turned off for every rider.
          final ff = ctx.read<FeatureFlagsService>();
          pr.featureOn = FeatureFlagsService.on;
          ff.addListener(pr.featureSwitchesChanged);
          return pr;
        }),
        ChangeNotifierProvider(create: (ctx) {
          final queue = SqfliteTrackQueue();
          // 3.56 (round 6): nothing is recorded within 300 m of a private place (phone-only list).
          PrivatePlacesStore.shared.load().ignore();
          return TrackRecorder(queue, TrackUploader(ctx.read<ApiClient>(), queue))..isPrivate = PrivatePlacesStore.shared.isNear;
        }),
        ChangeNotifierProvider<P2pMeshService>(create: (_) => P2pMeshService()),
        ChangeNotifierProvider(
          create: (ctx) {
            final convoys = ConvoyService(
              ctx.read<ApiClient>(),
              ctx.read<RealtimeService>(),
              ctx.read<TripStorageService>(),
              recorder: ctx.read<TrackRecorder>(),
              timeline: ctx.read<TimelineService>(),
              settings: ctx.read<SettingsService>(),
              mesh: ctx.read<P2pMeshService>(),
              onPlanChanged: () => ctx.read<MembershipService>().fetchMyMembership().ignore(),
            );
            // 3.55 riding role prompts ("You are now the sweeper, drop back...") in the important tier.
            convoys.speaker = (line, key) => ctx.read<VoiceService>().speak(line, priority: VoicePriority.important, key: key).ignore();
            // 3.55 admin feature switches (road warnings, riding roles): no hard dependency on the service.
            convoys.featureOn = FeatureFlagsService.on;
            final theme = ctx.read<ThemeController>();
            convoys.addListener(() {
              final me = convoys.myUserId == null ? null : convoys.activeConvoy?.riders[convoys.myUserId];
              if (me != null) theme.notePosition(me.lat, me.lng);
            });
            return convoys;
          },
        ),
        ChangeNotifierProvider<PhoneCallService>(
          create: (_) => PhoneCallService(),
        ),
        ChangeNotifierProvider(create: (ctx) {
          final intercom = IntercomService(ctx.read<RealtimeService>(), settings: ctx.read<SettingsService>());
          intercom.featureOn = FeatureFlagsService.on; // 3.55 admin feature switch 'intercom'
          // 3.55 fix: a switch turned off mid-ride also stops a talk in progress / an armed VOX mic.
          ctx.read<FeatureFlagsService>().addListener(intercom.featureSwitchesChanged);
          final phoneCall = ctx.read<PhoneCallService>();
          phoneCall.addListener(() => intercom.setPhoneCallActive(phoneCall.isCallActive));
          return intercom;
        }),
        // ==== Round 10 offline link BEGIN (docs/features_355/offline_long_range_link.md): Bluetooth LE Long Range
        // rider mesh + bridge + voice over the mesh, automatic. Advisories go through the round 7 scheduler gate.
        ChangeNotifierProvider<OfflineLinkService>(
          lazy: false,
          create: (ctx) {
            final link = OfflineLinkService(ctx.read<RealtimeService>(), ctx.read<ConvoyService>());
            final intercom = ctx.read<IntercomService>();
            intercom.offlineVoice = link;
            link.onVoicePacket = intercom.deliverOfflineVoice;
            link.advisoryGate = (key, text) => ctx.read<SafetyService>().roadCare.mayAdviseFallingBehind(key, text);
            link.speaker = (text, key) => ctx.read<VoiceService>().speak(text, priority: VoicePriority.warning, key: key).ignore();
            return link;
          },
        ),
        // ==== Round 10 offline link END
        // Spoken alerts (phone text-to-speech). The engine is warmed up at ride start (the ride
        // listener in the sound awareness block below; else the first alert starts it) and is
        // released when the ride ends (nothing runs at idle). 3.55 fix: released only when a group
        // ride ENDS (it used to be released on every convoy update without a group, i.e. all
        // through an offline solo ride, so each alert waited for the engine to start again).
        ChangeNotifierProvider<VoiceService>(create: (ctx) {
          final voice = VoiceService(ctx.read<SettingsService>());
          voice.attachPhoneCallService(ctx.read<PhoneCallService>());
          // Audio output diagnostics (latency, focus, music volume; no text, no names) to logcat.
          // 3.55: also into the persistent diagnostics log (alert latency, focus, music volume).
          AudioDiagLog.sink = (line) {
            debugPrint(line);
            DiagLog.info(DiagCat.audio, 'audio', {'line': line});
          };
          final convoys = ctx.read<ConvoyService>();
          var hadRide = false;
          convoys.addListener(() {
            final c = convoys.activeConvoy;
            final ride = c != null && c.tripStatus != 'ENDED';
            if (hadRide && !ride && voice.started) voice.release().ignore();
            hadRide = ride;
          });
          return voice;
        }),
        // Trip alerts (SOS, stopped, separated, no signal, arrivals), separate from the ongoing status.
        Provider<AlertService>(
          lazy: false,
          create: (ctx) => AlertService(ctx.read<ConvoyService>(), ctx.read<TimelineService>(), voice: ctx.read<VoiceService>()),
          dispose: (_, a) => a.dispose(),
        ),
        // Rider safety: crash alarm, emergency texts, break reminder, "Are you OK?" check-in,
        // fuel reminder, hard stops, follow-up, night voice, weather and tiles at ride start.
        // Created at start so a crash alarm can open without any screen asking for it.
        ChangeNotifierProvider<SafetyService>(
          lazy: false,
          create: (ctx) {
            final convoys = ctx.read<ConvoyService>();
            final settings = ctx.read<SettingsService>();
            final safety = SafetyService(convoys, settings, ctx.read<AuthService>(),
              voice: ctx.read<VoiceService>(), weather: ctx.read<WeatherService>(), tiles: ctx.read<TilePrefetcher>());
            safety.featureOn = FeatureFlagsService.on; // 3.55 admin feature switches (engine care)
            // 3.55: potholes, speed breakers and rough road felt at the front warn the riders
            // behind and are saved for later rides (ConvoyService decides whether to send).
            safety.onRoadSurface = convoys.reportRoadSurface;
            // 3.55 rider score: at ride end send the ride's counts (only while the rider's setting is on).
            final scoreApi = ctx.read<ApiClient>();
            safety.onRideStatsEnded = () => RiderScoreService.syncAfterRide(scoreApi);
            // Automatic offline maps (Nov 11): kept 7 days after the trip, then deleted (300 MB cap).
            safety.onTripEnded = (gid) => OfflineMapRetentionService.tripEnded(gid).ignore();
            // 3.57 phone-first emergency texts: an SOS closed anywhere sends "I'm safe now".
            convoys.onMySosClosed = safety.noteMySosClosed;
            // Round 4 road & safety intelligence: consent, warnings, uploads (docs/intelligence/).
            var deviceModel = '';
            SafetyNative.deviceInfo()
                .then(
                  (i) => deviceModel = '${i.manufacturer} ${i.model}'.trim(),
                )
                .ignore();
            safety.intel
              ..api = scoreApi
              ..deviceModel = (() => deviceModel)
              ..isLead = (() {
                final c = convoys.activeConvoy;
                final me = convoys.myUserId;
                return c != null &&
                    me != null &&
                    c.riders.length > 1 &&
                    (c.ridingLeadId == me || c.createdByUserId == me);
              });
            safety.intel
                .load()
                .then((_) => safety.intel.refreshConsent())
                .ignore();
            return safety;
          },
        ),
        // 3.55 SOS battery reserve: below 10% in a ride, keep power for SOS / crash detection,
        // pause heavy extras and send the last location to the group once.
        ChangeNotifierProvider<SosBatteryReserve>.value(value: SosBatteryReserve.shared),
        Provider<SosBatteryReserveBinding>(
          lazy: false,
          create: (ctx) {
            SosBatteryReserve.shared.featureOn = FeatureFlagsService.on; // switch 'sosBatteryReserve'
            return SosBatteryReserveBinding(ctx.read<ConvoyService>(),
                realtime: ctx.read<RealtimeService>(), tiles: ctx.read<TilePrefetcher>(), intercom: ctx.read<IntercomService>());
          },
          dispose: (_, b) => b.dispose(),
        ),
        // 3.55 diagnostics: ride start / end with battery and permission states, the gateway for
        // uploads and admin "Ask for logs" requests (socket / push DIAG_LOG_REQUEST).
        Provider<DiagRideObserver>(
          lazy: false,
          create: (ctx) {
            final convoys = ctx.read<ConvoyService>();
            final safety = ctx.read<SafetyService>();
            final settings = ctx.read<SettingsService>();
            DiagLogService.instance.attach(api: ctx.read<ApiClient>(), realtime: ctx.read<RealtimeService>(), push: ctx.read<PushService>());
            final o = DiagRideObserver(
              groupId: () => convoys.activeConvoy?.groupId,
              groupRideActive: () => convoys.activeConvoy?.tripStatus == 'STARTED',
              soloActive: () => safety.offlineSoloActive,
              batteryPercent: () => convoys.currentBatteryLevel,
              charging: () => convoys.isCharging,
              batterySaver: () => settings.batterySaver || convoys.batterySaverActive,
              riderCount: () => convoys.activeConvoy?.riders.length ?? 0,
            );
            convoys.addListener(o.changed);
            safety.addListener(o.changed);
            o.changed();
            return o;
          },
        ),
        // ==== 3.55 sound awareness (mic agent) BEGIN: one shared ride microphone (RideMicHub) for
        // siren detection and the intercom; alerts through VoiceService's priority manager.
        // Audio is analysed on the phone only. docs/features_355/sound_awareness_and_intercom.md
        ChangeNotifierProvider<RideMicHub>(
          lazy: false,
          create: (ctx) {
            final convoys = ctx.read<ConvoyService>();
            final safety = ctx.read<SafetyService>();
            final settings = ctx.read<SettingsService>();
            final intercom = ctx.read<IntercomService>();
            final hub = RideMicHub()
              ..rideActive = (() => convoys.activeConvoy?.tripStatus == 'STARTED' || safety.offlineSoloActive)
              ..batteryLow = (() =>
                  SosBatteryReserve.isActive || settings.batterySaver || (convoys.currentBatteryLevel < 15 && !convoys.isCharging))
              ..onNotice = ((m) => ctx.read<VoiceService>().speak(m, key: 'mic_permission_notice').ignore());
            intercom.micHub = hub;
            final phoneCall = ctx.read<PhoneCallService>();
            phoneCall.addListener(() => hub.setPhoneCallActive(phoneCall.isCallActive));
            void again() => hub.reevaluate().ignore();
            convoys.addListener(again);
            safety.addListener(again);
            settings.addListener(again);
            SosBatteryReserve.shared.addListener(again);
            return hub;
          },
        ),
        ChangeNotifierProvider<SirenAcousticDetector>(
          lazy: false,
          create: (ctx) {
            final convoys = ctx.read<ConvoyService>();
            final settings = ctx.read<SettingsService>();
            final intercom = ctx.read<IntercomService>();
            final voice = ctx.read<VoiceService>();
            final hub = ctx.read<RideMicHub>();
            final country = WidgetsBinding.instance.platformDispatcher.locale.countryCode;
            final d = SirenAcousticDetector(intercomService: intercom)
              ..speak = ((text, {required urgent, required key}) => voice.priorityManager.submit(
                    text: text,
                    priority: urgent ? AudioPriority.p1SafetyConfirmation : AudioPriority.p2ImmediateHazard,
                    dedupeKey: key,
                    pauseOthers: urgent,
                  ))
              ..tone = (() => NativeVoiceEngine.alertTone().ignore())
              ..sirenSettingOn = (() => settings.sirenAlerts)
              // Give-way side is fixed to Automatic (Nov 11): from the phone's country.
              ..giveWaySide = (() => SirenAcousticDetector.keepSideForCountry(country))
              ..intercomPlaying = (() => intercom.isReceiving)
              ..ownSpeechActive = (() => voice.priorityManager.isSpeaking)
              // Can the rider hear outside? Headset / music / call from the phone's audio state, no mic.
              ..readListening = NativeVoiceEngine.readListeningState;
            // 3.55: siren with the screen locked or the app in the background: a heads-up
            // with vibration (HapticFeedback may not vibrate then). In front: haptics only.
            d.backgroundAlert = (title, body, {required strong}) => AlarmNotifier.showSoundAwarenessAlert(title, body,
                showFor: strong ? const Duration(seconds: 60) : const Duration(seconds: 10));
            d.attachHub(hub);
            // 3.55: the ride foreground service starts as location|microphone (when the mic
            // permission is already granted) if siren alerts are on or the intercom may be used.
            final safetyForMic = ctx.read<SafetyService>();
            BackgroundService.micMayBeNeeded = () =>
                d.detectionWanted ||
                (FeatureFlagsService.on('intercom') &&
                    !safetyForMic.offlineSoloActive &&
                    (convoys.activeConvoy?.hasGroupFeatures ?? true));
            // Setting or admin switch off releases the mic at once; a new ride starts fresh.
            settings.addListener(d.settingsChanged);
            ctx.read<FeatureFlagsService>().addListener(d.settingsChanged);
            var wasRiding = false;
            void rideChanged() {
              final riding = hub.rideActive();
              if (riding && !wasRiding) {
                d.resetForRide();
                // Speech engine warm for the whole ride (bound, voice set, common lines ready):
                // the first alert no longer waits for the engine to start.
                voice.warmUp(phrases: SirenAcousticDetector.allSirenLines(keepSide: d.giveWaySide())).ignore();
              }
              if (!riding && wasRiding && voice.started && convoys.activeConvoy == null) voice.release().ignore(); // solo ride ended
              if (riding != wasRiding) d.setRideActive(riding);
              wasRiding = riding;
            }
            convoys.addListener(rideChanged);
            safetyForMic.addListener(rideChanged);
            rideChanged();
            return d;
          },
        ),
        // ==== 3.55 sound awareness (mic agent) END
        // ==== Round 10 rescue beacon BEGIN (docs/features_355/rescue_beacon.md). Victim side: after an
        // unanswered crash countdown or an unanswered "Still able to respond?" during an open SOS, an
        // escalating siren + near-ultrasonic locator + BLE locator + light. Responder side: the finder
        // (listens only during another rider's open SOS). Adds behaviour only; the countdown, SOS,
        // emergency texts and Medical ID are untouched.
        ChangeNotifierProvider<RescueBeaconService>(
          lazy: false,
          create: (ctx) {
            final convoys = ctx.read<ConvoyService>();
            final rescue = RescueBeaconService(
              AppRescueVictimPort(ctx.read<SafetyService>(), convoys),
              screenWake: (on) => SafetyNative.alarmWindow(on).ignore(),
            );
            RescueBeaconService.instance = rescue;
            RescueSpeakerCheck.storedMode().then((m) => rescue.bandMode = m).ignore();
            rescue.attachRealtime(ctx.read<RealtimeService>().events);
            // Speaker self-test (which locator band this phone plays): once a month, 20 s into a ride,
            // only while the ride mic is already open for siren alerts and no SOS is open.
            final hub = ctx.read<RideMicHub>();
            final speakerCheck = RescueSpeakerCheck(hub: hub, onResult: (m) => rescue.bandMode = m);
            var riding = false;
            void rideChanged() {
              final now = hub.rideActive();
              if (now && !riding) {
                Future<void>.delayed(const Duration(seconds: 20), () {
                  if (hub.rideActive() && !rescue.sosOpen && !rescue.active) speakerCheck.maybeRun().ignore();
                });
              }
              riding = now;
            }
            convoys.addListener(rideChanged);
            ctx.read<SafetyService>().addListener(rideChanged);
            return rescue;
          },
        ),
        ChangeNotifierProvider<RescueFinderService>(
          lazy: false,
          create: (ctx) {
            final convoys = ctx.read<ConvoyService>();
            final safety = ctx.read<SafetyService>();
            final rt = ctx.read<RealtimeService>();
            final finder = RescueFinderService(
              hub: ctx.read<RideMicHub>(),
              groupTargets: () => rescueGroupTargets(convoys),
              myPosition: () {
                final f = safety.lastFix;
                if (f != null) return (f.lat, f.lng);
                final uid = convoys.myUserId;
                final me = uid == null ? null : convoys.activeConvoy?.riders[uid];
                return (me?.lat ?? 0, me?.lng ?? 0);
              },
              sendMessage: rt.send,
              online: () => rt.isConnected,
              notify: (title, body) => AlarmNotifier.showCriticalAlert(title, body).ignore(),
            );
            finder.attachRealtime(rt.events);
            convoys.addListener(finder.reevaluate);
            return finder;
          },
        ),
        // ==== Round 10 rescue beacon END
        // 3.55 solo check-in by ETA (text the emergency contact when a solo ride is overdue and the
        // rider does not answer) and no-signal ahead (coverage log of my own rides). Not lazy: the
        // timer must run with the screen off.
        ChangeNotifierProvider<SoloGuardianService>(
          lazy: false,
          create: (ctx) => SoloGuardianService(
            ctx.read<ConvoyService>(),
            ctx.read<SettingsService>(),
            ctx.read<AuthService>(),
            ctx.read<RealtimeService>(),
            safety: ctx.read<SafetyService>(),
            voice: ctx.read<VoiceService>(),
            featureOn: FeatureFlagsService.on,
          ),
        ),
        // 3.55 group safety: missing-rider check, group stretch alert, smart regroup point, group
        // break planner, buddy pairs, risky-stretch heads-up. Logic on the phone; never speaks over
        // an SOS / crash alarm (docs/features_355/group_safety.md).
        ChangeNotifierProvider<GroupSafetyService>(
          lazy: false,
          create: (ctx) {
            final api = ctx.read<ApiClient>();
            final convoys = ctx.read<ConvoyService>();
            final safety = ctx.read<SafetyService>();
            final gs =
                GroupSafetyService(
                    convoys,
                    ctx.read<RealtimeService>(),
                    api,
                    timeline: ctx.read<TimelineService>(),
                    places: () => MapPlacesService.shared(api).all,
                  )
                  ..fatigueScore =
                      (() => safety.fatigueLevel) // 0-100 on the phone; only a level 0..3 is shared
                  ..hardStops = (() => safety.hardStops)
                  // 3.56: hard brakes feed the risky-stretch map only with the rider's road-data opt-in.
                  ..roadDataConsent = (() => safety.intel.consentOn)
                  ..alarmOpen = (() =>
                      safety.alarm != null || convoys.myOpenSosAlertId != null)
                  ..featureOn = FeatureFlagsService.on
                  ..speaker = ((line, key) => ctx
                      .read<VoiceService>()
                      .speak(line, priority: VoicePriority.important, key: key)
                      .ignore())
                  ..learnedStops = (() => safety.intel.learnedStops) // round 4: learned rider stops for regroup points
                  // round 7: falling-behind voice lines go through the one warning scheduler.
                  ..advisoryGate = safety.roadCare.mayAdviseFallingBehind;
            safety.intel.regroupName = () => gs.currentRegroupName;
            return gs;
          },
        ),
        // 3.55: CoRoute rider place reviews: a polite "How was it?" after a while at a place
        // (never while riding or during an SOS / crash alarm), ratings on the map and place card.
        ChangeNotifierProvider<PlaceReviewService>(
          lazy: false,
          create: (ctx) {
            final convoys = ctx.read<ConvoyService>();
            final safety = ctx.read<SafetyService>();
            final reviews = PlaceReviewService(ctx.read<ApiClient>())
              // 3.55 safety review: also any open SOS / crash alert of another rider in the ride.
              ..emergencyOpen = (() => SosBatteryReserve.isActive /* 3.55: no review prompts on SOS reserve */ || safety.alarm != null || convoys.pendingSos != null || convoys.myOpenSosAlertId != null ||
                  (convoys.activeConvoy?.activeAlerts.any((a) => !a.resolved) ?? false))
              ..rideActive = (() => convoys.activeConvoy != null && convoys.activeConvoy!.tripStatus != 'ENDED')
              ..rideIdSource = (() => convoys.activeConvoy?.groupId) // after-ride questions kept per ride
              ..attachFixes(convoys.myFixes);
            return reviews;
          },
        ),
        // 3.55: one garage for the whole app; its active bike feeds engine care, the fuel
        // profile (when the rider set none), the ride's vehicle colour and the profile summary.
        Provider<GarageService>.value(value: GarageService.shared),
        Provider<GarageBinding>(
          lazy: false,
          create: (ctx) {
            final convoys = ctx.read<ConvoyService>();
            return GarageBinding(
              ctx.read<GarageService>(),
              engineCare: ctx.read<SafetyService>().engineCare,
              fuelEconomy: ctx.read<SafetyService>().fuelEconomy, // 3.55 fix: bike change mid-ride
              auth: ctx.read<AuthService>(),
              settings: ctx.read<SettingsService>(),
              weather: ctx.read<WeatherService>(),
              onVehicle: convoys.setActiveVehicle, // 3.55: also tells the group mid-ride
              onBikeDetails: convoys.setActiveBikeDetails, // 3.55 bike type (map shape) and complete details
            );
          },
          dispose: (_, b) => b.dispose(),
        ),
        // 3.55 platform: HelmetVoiceService (hotwords) is no longer created at start-up. Nothing
        // feeds it speech (no recogniser; the mic runs only during PTT/VOX, FEAT-MIC-01), so it
        // only cost memory. Readers use context.read<HelmetVoiceService?>() and get null.
        // Register it here again (lazy) once a speech source exists.
        ChangeNotifierProvider<PermissionRevocationSafetyService>(
          lazy: false,
          create: (ctx) => PermissionRevocationSafetyService(
            convoyService: ctx.read<ConvoyService>(),
            intercomService: ctx.read<IntercomService>(),
          )..init(),
        ),
        Provider<FuelSharingBinding>(
          lazy: false,
          create: (ctx) => FuelSharingBinding(ctx.read<ConvoyService>(), ctx.read<SettingsService>(), ctx.read<SafetyService>()),
          dispose: (_, binding) => binding.dispose(),
        ),
        // In-app navigation to an emergency and accident warnings on my route (voice works with
        // the screen off, from fixes the ride already has).
        ChangeNotifierProvider<EmergencyGuidance>(
          lazy: false,
          create: (ctx) {
            final geo = GeoService(ctx.read<ApiClient>());
            return EmergencyGuidance(
              ctx.read<ConvoyService>(),
              ctx.read<VoiceService>(),
              ctx.read<SettingsService>(),
              fetchRoute: (wp) => geo.route(wp),
            );
          },
        ),
        ChangeNotifierProvider<RideEssentialsCoordinator>(
          lazy: false,
          create: (ctx) {
            final geo = GeoService(ctx.read<ApiClient>());
            return RideEssentialsCoordinator(
              ConvoyEssentialsPort(ctx.read<ConvoyService>()),
              ctx.read<SettingsService>(),
              RouteEssentialsService(ctx.read<ApiClient>()),
              fetchRoute: geo.route,
              reverseGeocode: geo.reverse,
              // Auto re-route: from where I am, in my direction of travel; short spoken lines.
              fetchRouteHeaded: (wp, heading) => geo.route(wp, startHeadingDeg: heading),
              onPrompt: NavVoice(ctx.read<VoiceService>()).say,
            );
          },
        ),
        // Medical ID on the lock screen / quick settings tile: always on, kept in step with the
        // profile (Agent 4: the on/off switch was removed; edit or clear the info instead).
        Provider<MedicalIdLockSync>(
          lazy: false,
          create: (ctx) => MedicalIdLockSync(ctx.read<AuthService>(), ctx.read<SettingsService>()),
          dispose: (_, m) => m.dispose(),
        ),
        // The big ride notification on the home and lock screen (replaces the plain one in place).
        Provider<RideNotificationService>(
          lazy: false,
          create: (ctx) {
            final settings = ctx.read<SettingsService>();
            final auth = ctx.read<AuthService>();
            final convoys = ctx.read<ConvoyService>();
            return RideNotificationService(
              convoys,
              ctx.read<TimelineService>(),
              settings,
              essentials: ctx.read<RideEssentialsCoordinator>(),
              safety: ctx.read<SafetyService>(),
              // 3.55: intercom state line + lock-screen Talk / Mute buttons.
              intercom: ctx.read<IntercomService>(),
              // Always on (Agent 4): the rider's medical ID badge on the lock screen during a ride
              // and the full line during their own SOS; empty when no medical info was entered.
              medicalId: () => MedicalId.fromAuth(auth),
              // Talk follows the ride's plan: a solo ride (Community host, one seat) has no Talk;
              // null while the seats are unknown (older gateway), so a group ride still shows it.
              talkAllowed: () {
                if (!FeatureFlagsService.on('intercom')) return false; // 3.55 admin feature switch
                final ride = convoys.activeConvoy;
                return ride == null || ride.capacity <= 0 ? null : ride.hasGroupFeatures;
              },
            );
          },
          dispose: (_, n) => n.dispose(),
        ),
        // 3.55 "Lower music when speeding" (admin switch speedAudio).
        Provider<SpeedAudioService>(
          lazy: false,
          create: (ctx) => SpeedAudioService(ctx.read<ConvoyService>(), ctx.read<SettingsService>(),
              safety: ctx.read<SafetyService>(), intercom: ctx.read<IntercomService>()),
          dispose: (_, s) => s.dispose(),
        ),
      ],
      child: const _SessionBinder(
        child: _DeepLinkListener(
          child: _App(),
        ),
      ),
    );
  }
}

class _App extends StatelessWidget {
  const _App();

  @override
  Widget build(BuildContext context) {
    final theme = context.watch<ThemeController>();
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      navigatorObservers: [
        appRouteObserver,
        PushRouterHost.observer,
        context.read<LockScreenCockpitService>().guard,
      ],
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeFor(theme.palette),
      // Colours switch at once everywhere; a cross-fade would mix the two themes.
      themeAnimationDuration: Duration.zero,
      // Round 7: the same iOS-style bounce on every list (lib/core/ui/app_motion.dart).
      scrollBehavior: const AppScrollBehavior(),
      home: const SplashScreen(),
      builder: (context, child) {
        // Large text is honoured up to 1.3x (every screen is laid out for it); beyond that it is capped.
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(mq.textScaler.scale(1.0).clamp(0.85, 1.3).toDouble())),
          // Round 10 rescue beacon: the victim's beacon screen over the lock screen + the screen flash.
          child: RescueBeaconHost(
            navigatorKey: appNavigatorKey,
            child: CrashAlarmHost(
            navigatorKey: appNavigatorKey,
            // 3.55 friend request / accepted: snackbar in the foreground (system notification in the background).
            child: FriendNoticeHost(
              navigatorKey: appNavigatorKey,
              // 3.55 push notifications: tapped push -> the right screen; foreground push -> snackbar.
              child: PushRouterHost(
                navigatorKey: appNavigatorKey,
                // 3.55 ride invitations: shown by themselves on app open / resume, banner on RIDE_INVITE.
                child: RideInviteHost(
                  navigatorKey: appNavigatorKey,
                  // 3.55 diagnostics: "send the log of this ride?" after a safety moment; support's log request.
                  child: DiagPromptHost(
                    navigatorKey: appNavigatorKey,
                    // Round 4: "Help make roads safer?" once after the first ride; "Was this a real crash?" after a
                    // cancelled alarm. Never during a ride or an alarm.
                    child: IntelPromptHost(
                      navigatorKey: appNavigatorKey,
                      // Locked cockpit (padlock chip, private screens covered until the unlock) over the round 4 app
                      // lock (above the screens, below the crash alarm and the SOS flows). They never show together.
                      child: LockedCockpitGate(
                        child: AppLockGate(
                          navigatorKey: appNavigatorKey,
                          child: _UpdateGate(
                            child: child ?? const SizedBox.shrink(),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          ), // Round 10 RescueBeaconHost
        );
      },
    );
  }
}

/// Blocks the app when the server says this build is too old to be safe.
class _UpdateGate extends StatelessWidget {
  final Widget child;
  const _UpdateGate({required this.child});

  @override
  Widget build(BuildContext context) {
    final meta = context.watch<MetaService>();
    if (!meta.updateRequired) return child;
    final url = meta.meta?.downloadUrl ?? '';
    return Material(
      color: AppTheme.obsidianVoid,
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Space.s24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: Radii.lgAll,
                    child: Image.asset('assets/branding/coroute_icon.png', width: 72, height: 72, cacheWidth: 216),
                  ),
                  const SizedBox(height: Space.s24),
                  Text('Update required', textAlign: TextAlign.center, style: AppText.title),
                  const SizedBox(height: Space.s8),
                  Text(
                    'This version of CoRoute no longer works with the convoy service. Install the latest version to keep riding with your group.',
                    textAlign: TextAlign.center,
                    style: AppText.body.copyWith(color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: Space.s24),
                  FilledButton(
                    onPressed: url.isEmpty ? null : () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
                    style: FilledButton.styleFrom(minimumSize: const Size(200, 56)),
                    child: const Text('Get the update'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens/closes the realtime session whenever authentication changes, and
/// returns to the sign-in screen when a session ends while the app is open.
class _SessionBinder extends StatefulWidget {
  final Widget child;
  const _SessionBinder({required this.child});

  @override
  State<_SessionBinder> createState() => _SessionBinderState();
}

class _SessionBinderState extends State<_SessionBinder> {
  String? _boundUserId;
  bool _wired = false;
  String _shownNotice = '';
  List<Listenable> _lockCockpitSources = const [];
  VoidCallback? _lockCockpitRefresh;

  /// 3.57: what a sign-out must wait for (lib/data/services/session_guard.dart), the push token removed before
  /// the session is revoked, cached personal data wiped after it, and the "signed out after the ride" notice.
  void _wire() {
    if (_wired) return;
    _wired = true;
    final convoys = context.read<ConvoyService>();
    final auth = context.read<AuthService>();
    final push = context.read<PushService>();
    final trips = context.read<TripStorageService>();
    SessionGuard.instance.probe = () {
      final safety = SafetyService.hasInstance ? SafetyService.instance : null;
      return RideSafetyState(
        inConvoy: convoys.activeConvoy != null,
        rideActive: safety?.rideOn ?? false,
        sosOrCountdown:
            (safety?.emergencyOpen ?? false) || convoys.pendingSos != null,
        pendingEmergencyTexts: safety?.emergencyTextsPending ?? false,
      );
    };
    // Round 4 app lock: armed only while signed in; the cold-start check runs once the saved session is read.
    final lock = context.read<AppLockService>();
    lock.signedIn = () => auth.isAuthenticated;
    if (!auth.isLoading) {
      lock.start().ignore();
    } else {
      void waitLoaded() {
        if (auth.isLoading) return;
        auth.removeListener(waitLoaded);
        lock.start().ignore();
      }

      auth.addListener(waitLoaded);
    }
    // Cockpit on the lock screen: re-checked whenever the ride, the sign-in or the setting changes.
    final lockCockpit = context.read<LockScreenCockpitService>();
    final settings = context.read<SettingsService>();
    lockCockpit
      ..signedIn = (() => auth.isAuthenticated)
      ..settingOn = (() => settings.rideOnLockScreen)
      ..safetyFlowOpen = (() =>
          SosHoldScreen.isOpen ||
          EmergencySosSheet.isShowing ||
          (SafetyService.hasInstance && SafetyService.instance.alarm != null));
    _lockCockpitSources = [
      auth,
      settings,
      convoys,
      context.read<SafetyService>(),
      SessionGuard.instance,
    ];
    _lockCockpitRefresh = lockCockpit.refresh;
    for (final l in _lockCockpitSources) {
      l.addListener(lockCockpit.refresh);
    }
    lockCockpit.start().ignore();
    auth.beforeSignOut.add(push.unregisterNow);
    auth.afterSignOut.add(trips.clearLocal);
    auth.afterSignOut.add(StartupWarmup.reset); // round 7: screen caches (profiles, crews, leaderboard) forgotten at sign-out
    SessionGuard.instance.addListener(_guardChanged);
  }

  void _guardChanged() {
    final msg = SessionGuard.instance.pendingMessage;
    if (msg.isEmpty || msg == _shownNotice) {
      if (msg.isEmpty) _shownNotice = '';
      return;
    }
    _shownNotice = msg;
    final ctx = appNavigatorKey.currentContext;
    if (ctx == null) return;
    ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 8)),
    );
  }

  @override
  void dispose() {
    SessionGuard.instance.removeListener(_guardChanged);
    final refresh = _lockCockpitRefresh;
    if (refresh != null) {
      for (final l in _lockCockpitSources) {
        l.removeListener(refresh);
      }
    }
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _wire();
    final auth = context.watch<AuthService>();
    final convoys = context.read<ConvoyService>();
    final intercom = context.read<IntercomService>();
    final trips = context.read<TripStorageService>();

    if (auth.isAuthenticated && auth.currentUserId != _boundUserId) {
      _boundUserId = auth.currentUserId;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        convoys.startSession(token: auth.token ?? '', userId: auth.currentUserId!, admin: auth.isMasterAdmin);
        trips.syncWithCloud(userId: auth.currentUserId);
        // Round 7: next-likely screens' data after a few idle seconds (never during a ride).
        if (mounted) StartupWarmup.schedule(context, userId: auth.currentUserId!);
      });
    } else if (!auth.isAuthenticated && _boundUserId != null) {
      _boundUserId = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        intercom.reset();
        convoys.endSession();
        trips.clearLocal();
        // Session expired, was revoked, or the account was deleted: back to sign-in.
        final nav = appNavigatorKey.currentState;
        if (nav != null) {
          nav.pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const AccessGateScreen()), (_) => false);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Handles `coroute://join/CODE` and `https://<host>/join/CODE` links, and
/// `coroute://subscription` (re-reads the plan). No other link opens a plan screen
/// (Play payments policy, docs/features_355/play_payments_policy.md).
class _DeepLinkListener extends StatefulWidget {
  final Widget child;
  const _DeepLinkListener({required this.child});

  @override
  State<_DeepLinkListener> createState() => _DeepLinkListenerState();
}

class _DeepLinkListenerState extends State<_DeepLinkListener> {
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _sub;
  // 3.56 "Share to CoRoute": a maps place shared from another app opens the planner.
  late final ShareInOpener _shareIn = ShareInOpener(navigatorKey: appNavigatorKey, readContext: () => mounted ? context : null);

  @override
  void initState() {
    super.initState();
    _shareIn.start();
    _appLinks.getInitialLink().then((uri) {
      if (uri != null) _handle(uri);
    }).catchError((_) {});
    _sub = _appLinks.uriLinkStream.listen(_handle, onError: (_) {});
  }

  void _handle(Uri uri) {
    if (uri.scheme == 'coroute' && uri.host == 'cockpit') {
      // Return link from external navigation; activity is brought to foreground.
      return;
    }
    if (uri.scheme == 'coroute' && uri.host == 'subscription') {
      // coroute://subscription: re-read the membership (the single source of the plan). Nothing else.
      context.read<MembershipService>().fetchMyMembership().ignore();
      return;
    }
    // 3.55 friend invite link (https://<site>/join/friend/<CODE>, coroute://join/friend/<CODE>).
    final invite = InviteCodes.fromUri(uri);
    if (invite != null) {
      context.read<FriendsService>().handleInviteCode(invite).ignore();
      return;
    }
    if (uri.pathSegments.contains('friend')) return; // a malformed invite is never a ride join code
    final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    String? code;
    if (uri.scheme == 'coroute' && uri.host == 'join' && segs.isNotEmpty) code = segs.first;
    if (segs.length >= 2 && segs[segs.length - 2] == 'join') code = segs.last;
    if (code == null) return;
    context.read<ConvoyService>().setPendingJoinCode(code);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _shareIn.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
