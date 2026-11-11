# CoRoute mobile app (Android, Flutter)

Written 11 Nov 2026 from `lib/` (458 Dart files), `android/app/` and `pubspec.yaml`
(`version: 3.55.0+10022`). iOS folders exist but iOS is "building, coming soon" (no App Store
release).

## 1. Build facts

| Item | Value |
|---|---|
| Package | `space.devmonks.coroute_app` |
| Flutter / Dart | 3.47.1 / 3.13.1 (`sdk: ^3.13.1`) |
| Android | minSdk `max(flutter.minSdkVersion, 23)`, **targetSdk 36** (Play: API 36 for updates from 31 Aug 2026), compileSdk 37 |
| Key packages | `provider`, `flutter_map`, `geolocator`, `web_socket_channel`, `record` (mic), `flutter_pcm_sound`, `flutter_foreground_task`, `flutter_local_notifications`, `permission_handler`, `flutter_secure_storage`, `sqflite`, `shared_preferences`, `google_sign_in`, `app_links`, `battery_plus`, `wakelock_plus`, `share_plus`, `url_launcher`, `image_picker`, `flutter_compass` |
| Native deps (Gradle) | `firebase-bom:33.7.0` + `firebase-messaging` (no Analytics, no google-services plugin), `com.google.android.play:review:2.0.2` |
| Build-time values | `COROUTE_API` (optional override; disables the DuckDNS fallback, so **not** used for release), `GOOGLE_WEB_CLIENT_ID` (public id, has a default), Gradle properties `COROUTE_FCM_APP_ID`, `COROUTE_FCM_API_KEY`, `COROUTE_FCM_PROJECT_ID`, `COROUTE_FCM_SENDER_ID` (without them push is simply off) |
| Signing | `android/key.properties` + keystore, git-ignored, never committed |

Gateway hosts: `AppConfig.defaultApiBaseUrl` = `https://coroute.devmonks.space`, fallback
`https://coroute.duckdns.org` (`lib/core/config/app_config.dart`, `gateway_hosts.dart`). Release
builds accept only `https://` gateways and always use `wss://<host>/ws`.

## 2. Code structure

```
lib/
  main.dart                 guarded zone, error capture, service construction, MultiProvider (48 providers)
  core/
    config/                 app_config.dart, gateway_hosts.dart, feature_gates.dart (plan / access map)
    constants/              app, navigation, notification, safety constants (SafetyConstants)
    l10n/                   L10n: English, Hindi, Telugu (+ "System" language)
    theme/                  app_palette.dart (design tokens), app_theme.dart, theme_controller.dart, map_tiles.dart
    ui/                     design_kit.dart (Ds* primitives), sos_button.dart, ride_alert.dart, ui_tokens.dart ...
    widgets/                shared widgets
  data/
    local/                  outbox_store, sqflite_track_queue, roster_store (encrypted SMS roster),
                            saved_map_pack_store, ride_stats_store, review_prompt_store
    models/                 convoy_model, membership_model (capabilities), rider models ...
    services/               ~80 services (see §3)
  domain/                   pure logic, unit-tested without Flutter
    audio/ diag/ engagement/ fuel/ garage/ geo/ group/ membership/ mesh/ navigation/ notify/
    places/ ride/ route/ safety/ score/ social/ sync/ timeline/ tracking/ voice/ analytics/
  presentation/             screens and sheets
    account/ admin/ alerts/ analytics/ auth/ diagnostics/ engagement/ garage/ home/ map_picker/
    map_places/ onboarding/ report/ review/ ride/ rider/ safety/ score/ settings/ social/ splash/
    subscription/ timeline/ trip/ trip_planner/ update/ widgets/
```

Layering rule: `domain/` is pure Dart (no Flutter, no IO) and holds the decisions (crash rule,
speed estimator, sound alert policy, retention, plan gate messages, ride tap gate ...).
`data/services/` adapts platform, network and storage; `presentation/` renders. Most bugs fixed in
3.55 came with a pure `domain/` test.

### 2.1 State management

`provider` with plain services (`Provider<T>`) and a few `ChangeNotifier`s (`ThemeController`,
`DiagLogService`, `SosBatteryReserve`, `ConvoyService`, `MembershipService` ...). Services are built
once in `main.dart` and wired to each other there (for example `AlertService.urgentPoster =
RideNotificationChannel.postUrgent`, push router hooks, audio diagnostics sink).

## 3. Main services

| Area | Services |
|---|---|
| Network | `api_client.dart` (REST, `X-Request-Id`, token refresh from `X-CoRoute-Token`, diagnostics on errors), `realtime_service.dart` (WebSocket, HELLO features, reconnect, host fallback), `meta_service.dart`, `app_version_service.dart` |
| Ride | `convoy_service.dart` (rooms, telemetry, roles, swaps, pillion, capabilities, outbox), `timeline_service.dart`, `track_recorder.dart`, `track_uploader.dart`, `trip_storage_service.dart`, `background_service.dart` (foreground service), `ride_notification_service.dart`, `ride_chat_store.dart`, `public_ride_service.dart` |
| Safety | `safety_service.dart` (crash alarm, SOS, SMS round, check-ins, speed warning), `sensor_safety_hub.dart`, `accel_source.dart`, `alert_service.dart`, `alarm_notifier.dart`, `group_safety_service.dart`, `solo_guardian_service.dart`, `sos_battery_reserve.dart`, `medical_id_lock_sync.dart`, `permission_revocation_safety_service.dart`, `sms_sender.dart`, `ble_remote_service.dart`, `p2p_mesh_service.dart` + `udp_broadcast_mesh_transport.dart` (offline SOS relay) |
| Audio | `ride_mic_hub.dart`, `siren_acoustic_detector.dart`, `intercom_service.dart`, `voice_service.dart`, `audio_priority_manager.dart`, `speed_audio_service.dart`, `phone_call_service.dart`, `nav_voice.dart`, `helmet_voice_service.dart` |
| Maps and route | `geo_service.dart`, `map_places_service.dart`, `route_essentials_service.dart`, `ride_essentials_coordinator.dart`, `tile_cache_service.dart`, `offline_map_retention_service.dart`, `nav_handoff_service.dart`, `weather_service.dart` |
| Account and plans | `auth_service.dart`, `membership_service.dart` (`canHostGroup`, capabilities), `feature_flags_service.dart`, `settings_service.dart` |
| Social | `friends_service.dart`, `crews_service.dart`, `ride_invites_service.dart`, `rider_score_service.dart`, `push_service.dart`, `engagement_service.dart`, `place_review_service.dart`, `admin_warnings_service.dart` |
| Garage and fuel | `garage_service.dart`, `garage_binding.dart`, `fuel_economy_service.dart`, `fuel_settings_binding.dart`, `fuel_sharing_binding.dart`, `road_care_service.dart` |
| Diagnostics | `diag_log_service.dart`, `device_diagnostic_service.dart` |

## 4. Platform channels (Kotlin, `android/app/src/main/kotlin/...`)

| Channel | Kotlin | Used for |
|---|---|---|
| `coroute/accel` (EventChannel) | `AccelStream.kt` | Motion buckets for crash / rider-down / road surface (peak g, dynamic g, gyro, tilt vs riding baseline) |
| `coroute/tts` | `TtsChannel.kt` | Speech with audio focus (`USAGE_ASSISTANCE_NAVIGATION_GUIDANCE`, transient duck), alarm stream for critical lines, `listeningState` (headset, music, call) |
| `coroute_media_volume_guard` | `MediaVolumeGuard.kt` | Lower / restore music when speeding without fighting the rider |
| `coroute/phone_call`, `coroute/phone_call_events` | `PhoneCallChannel.kt` | Call state for call-aware alerts |
| `coroute/ride_notification` | `RideNotification.kt` | Rich ride notification (speed, limit, buttons SOS / Talk / Mute / Leave), urgent full-screen posts |
| (activities) | `UrgentAlertActivity.kt`, `RideSosActivity`, `MedicalIdActivity.kt`, `MedicalTileService.kt` | Another rider's SOS over the lock screen, SOS hold screen, Medical ID on the lock screen, quick-settings tile |
| `coroute/sms` | `SmsChannel.kt`, `EmergencyTexts.kt` | 3.57 phone-first emergency texts (enqueue / cancelTexts / textStatuses, "textStatus" back to Dart; sent+delivered reports, retries, survives app kill); fallback: open the messages app prefilled (keyguard dismiss first) |
| `coroute/safety` | `SafetyChannel.kt` | Phone check fixes: notification settings, app battery page, battery optimisation dialog, full-screen intent page |
| `coroute/push` | `PushChannel.kt`, `CoRouteMessagingService.kt` | FCM init from build values, token, per-kind channels and opt-outs, launch message |
| `coroute/in_app_review` | `InAppReviewChannel.kt` | Google Play in-app review card |
| `coroute/nav_handoff` | `NavHandoffChannel.kt` | Navigate in Google Maps (two-wheeler) / Mappls / any map app (manifest `<queries>`) |
| `coroute/share_in` | `ShareInActivity.kt` | "Share to CoRoute" from Google Maps and other apps |
| `coroute/install_referrer` | `MainActivity.kt` (handler set to `null`) | **Retired.** The coupon-from-Play-referrer path (Nov 9) was removed by the 3.56 payments policy; the channel is unregistered and the Install Referrer SDK is forbidden by the policy scan (0 hits on 11 Nov 2026). |
| `coroute/audio_watchdog`, `coroute/ambient_light` | `MainActivity.kt` | Audio watchdog; ambient light for night map |
| (crash log) | `CrashLog.kt` | Native crashes and main-thread stalls merged into the diagnostics log at next start |

Kotlin files added in 3.55/3.56 were written without an Android SDK in the authoring environment;
their **first compile** is part of the release procedure (MASTER_AGENT_PROMPT section 3.5).

## 5. Permissions (manifest)

| Permission | Why | Play declaration |
|---|---|---|
| `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION` | Group map, SOS position | Data safety: precise location |
| `ACCESS_BACKGROUND_LOCATION` | Keep sharing position and SOS working with the screen off during a ride | Sensitive permission form + video |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION`, `FOREGROUND_SERVICE_MICROPHONE` | Ride foreground service, type `location|microphone` (microphone only when granted) | FGS declaration |
| `RECORD_AUDIO`, `MODIFY_AUDIO_SETTINGS`, `BLUETOOTH_CONNECT` | Intercom, siren detection, headset routing | Data safety: audio not stored |
| `POST_NOTIFICATIONS` | Ride notification, alerts, push | — |
| `USE_FULL_SCREEN_INTENT` | Crash alarm and other riders' SOS over the lock screen | Full-screen intent declaration (Android 14+) |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Keep rides alive on aggressive OEMs | Must be justified; fallback: open battery settings |
| `ACCESS_NOTIFICATION_POLICY` | Critical alerts through Do Not Disturb (when allowed) | — |
| `WAKE_LOCK`, `VIBRATE`, `RECEIVE_BOOT_COMPLETED`, `INTERNET`, `ACCESS_NETWORK_STATE` | Normal | — |

Requested since 3.57: `SEND_SMS` (after the in-app disclosure; emergency texts from the rider's SIM). Not requested: `READ_SMS`, `RECEIVE_SMS`, `READ_PHONE_STATE`, camera beyond `image_picker`,
contacts, phone state beyond what `PhoneCallChannel` needs. Runtime requests go through
`permissions_service.dart`; the mic is never requested mid-ride for siren detection.

## 6. Background service

`background_service.dart` runs one foreground service via `flutter_foreground_task` while a ride is
active: type `location`, plus `microphone` only when the rider granted the mic (Android 14 refuses
a microphone FGS without it). `BackgroundService.ensureMicrophoneType()` restarts the service with
the microphone type only while the app is in front. During a ride the plain notification is
replaced in place by the rich ride notification (`RideNotificationService`, same id and channel).
The notification actions never act alone: SOS opens the hold-to-send screen, Leave opens a confirm.

Notification channels include the ride channel, **Critical ride alerts** and **SOS (v2)**
(`coroute_sos_v2`, alarm sound, DND bypass), Friends, Ride invites, plan reminders and the push
kinds `coroute_news`, `coroute_events`, `coroute_safety_tips`, `coroute_community`,
`coroute_partner_perks`.

## 7. Settings and migrations

Owner direction: minimal settings, safe defaults ([docs/SETTINGS_MINIMAL_v3.55.md](../../SETTINGS_MINIMAL_v3.55.md)).

- Safety settings have **no switch**: crash detection, SOS (incl. lock screen), emergency texts,
  Medical ID on the lock screen, check-ins, solo ETA check-in, no-signal ahead, break reminder,
  road warnings, auto re-route, voice cleanup, keep screen on, help nearby riders, ask nearby riders.
- Visible rows: Emergency contact & Medical ID, speed warning limit, voice alerts, **Siren alerts**
  (on by default), language, battery saver, data saver, appearance, push notifications, show me on
  leaderboards, Safety health. Under **More**: pause music for alerts, lower music when speeding,
  fuel, permissions, features guide.
- `SettingsService.alwaysOnKeys` + `safetyDefaultsVersion` (now **2**) run one-time migrations:
  v1 forces always-on keys to true; v2 resets give-way side to Automatic and turns the score's
  safety report on (with a send-from cut-off so rides recorded while off are never sent). Setters
  refuse "off" silently. The migration never turns anything off.
- `AuthService` writes `PATCH /me {assistHelp:true, assistAsk:true}` once per run when the server
  still says off (skipped while admin switch `assistNetwork` is off).
- Settings apply live mid-ride ([docs/SETTINGS_LIVE_AUDIT_v3.55.md](../../SETTINGS_LIVE_AUDIT_v3.55.md)).

## 8. Feature flags in the app

- Admin **feature switches** (67 ids in 6 groups, `gateway/src/feature_flags.js`) arrive by
  `GET /api/features` and the `FEATURE_FLAGS` socket message; `FeatureFlagsService` caches them and
  `feature_switch.dart` gates UI and behaviour. Unknown or unreadable = **on**. Locked ids (`sos`,
  `crashDetection`, `emergencySms`, `medicalId`) are always on. A setting row whose admin switch is
  off is hidden, and the service still checks at use time.
- **Capabilities** (access mode) decide hosting and ride size: `MembershipService.canHostGroup`,
  `ConvoyModel.groupFeatures` / `allowsGroupFeature`; texts from
  `lib/domain/membership/plan_gate_messages.dart`. The app never shows prices or plans.
- `lib/core/config/feature_gates.dart` maps features to `FeatureAccess.safety / groupRide /
  personal` (safety never gated).

## 9. Diagnostics logging

`lib/domain/diag/` + `diag_log_service.dart` ([docs/features_355/diagnostics_logs.md](../../features_355/diagnostics_logs.md)):

- One JSON line per entry (`t`, `m`, `l`, `c`, `e`, `f`, `b`, `s`, `r`, `n`) in `<filesDir>/diag`,
  files of 2 MB, total 20 MB, **7 days**. Levels I/W/E always; debug only with "Detailed logs"
  (auto-off after 24 h).
- `diag_redact.dart`: no message text, names, usernames, phones, e-mails, medical info, tokens,
  addresses; free text scrubbed; lat/lng rounded to 3 decimals and only during a ride; account ids
  replaced by a phone-only code. The server redacts again (`gateway/src/diag_logs.js`).
- Sent only when the rider chooses: Profile > Help > Send feedback > Attach diagnostics log (or
  View diagnostics > Send), after an SOS/crash when the app asks, or when an admin requests it and
  the rider taps Send. Server keeps 30 days; views audited.
- Uncaught errors (zone, Flutter, isolate) and native crashes (`CrashLog.kt`) feed the log.
- Offline analysis helper: `tool/diag/analyze_logs.js`.

## 10. Play policy scan

`tool/play_policy_scan.dart` must print **0 hits** before every release:

- Forbidden SDKs in pubspec, Gradle, ProGuard, manifest: Razorpay, Play Billing, Stripe, Paytm,
  PhonePe, Cashfree, PayU, Install Referrer, `upi` scheme.
- Forbidden words in every rider-visible string literal (Dart, Android XML, Kotlin, text assets):
  `razorpay, ₹, INR, price, pricing, per month, upgrade, purchase, buy, buying, checkout, coupon,
  discount, renew, payment`. A short, reasoned allowlist covers non-UI literals.
- Run: `dart run tool/play_policy_scan.dart` from the repo root (exit 1 on any hit).

## 11. Design system and naming

- Tokens: `lib/core/theme/app_palette.dart`; primitives `lib/core/ui/design_kit.dart`
  (`DsScreenHeader`, `DsSectionHeader`, `DsChip` ...). Guide: [docs/DESIGN_SYSTEM_v3.55.md](../../DESIGN_SYSTEM_v3.55.md).
- One name per concept: [docs/UX_NAMING_GUIDE_v3.55.md](../../UX_NAMING_GUIDE_v3.55.md) and
  [glossary.md](glossary.md). Sentence-case titles, 48 dp buttons, `km/h`, Indian English.
