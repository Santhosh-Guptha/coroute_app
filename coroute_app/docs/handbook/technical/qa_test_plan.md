# CoRoute QA test plan

Written 11 Nov 2026. Companion to the formal layered plan [docs/testing/test_plan.md](../../testing/test_plan.md),
[release_gates.md](../../testing/release_gates.md), [safety_invariants.md](../../testing/safety_invariants.md),
[requirements_traceability.md](../../testing/requirements_traceability.md) and the scenario lists
[docs/SAFETY_DEVICE_TESTS.md](../../SAFETY_DEVICE_TESTS.md), [docs/NEW_FEATURE_TEST_SCENARIOS.md](../../NEW_FEATURE_TEST_SCENARIOS.md),
[docs/SAFETY_SCENARIO_REVIEW_v3.55.md](../../SAFETY_SCENARIO_REVIEW_v3.55.md).

## 1. Current automated results

| Suite | Result | Date / who |
|---|---|---|
| Gateway `npm test` (152 files) | **1,091 / 1,091 pass**, 174 s | 11 Nov 2026, handbook agent |
| Play policy scan | **0 hits** | 11 Nov 2026, handbook agent |
| Flutter `flutter test` (238 files, ~2,176 cases) | last full run 2,142 / 2,146 (4 `ui_audit` path_provider tests need a device) | 10 Nov 2026 (PROJECT_CONTEXT); not runnable in the handbook environment (no Flutter engine) |
| `flutter analyze` | no issues (last recorded) | Nov 2026 |
| Gradle release build of the new Kotlin | **not yet compiled** for the 3.56 files | release gate |

## 2. Automated test inventory by area

### 2.1 Gateway (`gateway/test/*.test.js`)

| Area | Suites |
|---|---|
| SOS, alerts, safety core | `sos`, `safety_sos`, `safety_behaviour`, `safety_review_355`, `incident`, `follow_up_admin`, `emergency_status`, `live_link`, `live_page`, `hospital`, `sweeper`, `arrivals`, `convoy_watchdog`, `group_safety_355`, `pillion_seat_355`, `roster`, `outbox` |
| Safety network and discovery | `safety_network`, `net_behaviour`, `net_compat`, `net_geo`, `net_hazard`, `net_privacy`, `net_abuse`, `far_by_road`, `discovery`, `public_ride`, `public_rider_help`, `public_ride_mirror` |
| SMS | `emergency_sms_gateway`, `sos_sms_355` |
| Guardian | `guardians`, `guardians_integration`, `guardian_arrival`, `guardian_push`, `guardian_push_http`, `guardian_browser` |
| Rides, timeline, tracks | `timeline`, `timeline_tick_load_355`, `overspeed`, `route`, `geo_reroute`, `ride316_rules`, `ride_roles_355`, `ride_swap_355`, `rider_vehicle_355`, `config_live_355`, `presence`, `room_snapshot`, `track_batching`, `track_gap`, `track_simplify`, `trips_summary`, `trip_route_truth`, `scenario_convoy`, `scenario_extreme_riding`, `ride_scenarios_e`, `qa316_behaviour`, `qa_adversarial`, `large_group_security_e`, `join_limits`, `rider_patch`, `ride_chat_report` |
| Two-node and platform | `two_node_failover`, `two_node_swaps_roles`, `push_two_node_355`, `job_lease`, `gateway_role`, `trust_proxy`, `soda_atomic`, `backups`, `object_store`, `review_photos_par`, `key_rotation`, `domain_migration`, `app_builds`, `gateway` |
| Auth and accounts | `session`, `password_hashing`, `account_gate`, `account_delete`, `staff_accounts`, `admin_management`, `security_deep_audit`, `audit_fixes`, `validation`, `plain_text`, `cross_group_privacy`, `profile_medical`, `profile_bike_355`, `bike_details_once_356` |
| Plans, payments, access | `access_mode_356`, `membership`, `membership_plans`, `plans_v2`, `plans_cleanup_355`, `plan_offers_355`, `subscription`, `coupon_admin`, `coupon_records`, `payment_security_and_zero_activation`, `web_payments_security_355`, `web_plans_355`, `purchase_email_355`, `site_max_riders` |
| Social | `usernames_friends_355`, `friends_app_contract_355`, `user_search_355`, `crews_polls_355`, `crew_ride_invites_355`, `rider_score_355`, `website_leaderboard_355` |
| Push, mail, marketing | `push_355`, `push_campaigns_355`, `push_kinds_offers_email_356`, `play_policy_push_355`, `marketing_templates_355`, `marketing_board_355`, `engagement_355` |
| Operators | `operators_356` |
| Admin | `web_admin_355`, `admin_analytics`, `admin_analytics_paging`, `admin_analytics_trends`, `admin_warnings`, `feature_flags_355`, `feature_policy`, `diagnostics`, `diagnostics_355`, `community_stats_and_feedback`, `feedback_app_ideas` |
| Maps and road | `geo`, `geo_photon`, `geo_links_356`, `essentials`, `essentials_integration`, `poi_cells`, `weather`, `road_and_places_355`, `road_hazard_gateway` |
| Reviews | `trip_reviews`, `trip_reviews_photos`, `trip_reviews_real_ride` |
| Website | `website`, `website_live`, `website_impact_355`, `website_ios_blocks`, `website_play_blocks`, `website_privacy_messaging`, `website_stories_render`, `website_get_coupon_355`, `public_stats_alltime_355` |

### 2.2 App (`test/`)

| Area | Examples |
|---|---|
| Crash / SOS | `crash_detector`, `advanced_crash_detection`, `crash_false_positive_guards`, `sos_false_alarm_355`, `crash_alarm_screen`, `sos_hold_screen`, `sos_queue`, `sms_fallback`, `sos_sms_text_356`, `missing_rider_sos_355`, `emergency_roster`, `medical_info_share`, `medical_id_sync`, `offline_safety_and_crash`, `scenario_f_indian_emergency_fallback`, `failover_resend` |
| Sensor safety | `sensor_safety_355`, `sensor_safety_355_service`, `hard_brake`, `fatigue_checkin`, `solo_eta_check_in`, `pillion_group_safety_355`, `group_safety_355`, `roll_call` |
| Audio | `siren_detector_355`, `siren_acoustic_detector`, `sound_alert_policy`, `voice_cleanup_355`, `audio_and_calls_355`, `call_alert_queue`, `speed_audio_policy`, `audio_priority_and_fatigue`, `intercom_*`, `microphone_lifecycle_and_privacy`, `bystander_siren` |
| Alerts and latency | `alert_latency_355`, `alert_priority`, `alert_persistence`, `notice_dedupe_355`, `effective_speed_limit`, `speed_estimator`, `location_cadence` |
| Settings and profile | `settings_minimal_355`, `settings_live_355`, `profile_minimal`, `network_settings`, `network_settings_ui`, `group_settings_release_355`, `feature_flags` |
| Plans and access | `access_mode_gate_messages_356`, `membership`, `membership_plan_access`, `plans_v2`, `trip_creation_membership_gate`, `your_plan_card` |
| Maps and routes | `offline_map_retention`, `offline_maps_and_navigation`, `map_link_parser_356`, `nav_handoff`, `route_*`, `off_route_group_355`, `heritage_places_355`, `road_context_355`, `road_places_355` |
| Network | `reconnect_policy`, `network_recovery_integration`, `gateway_hosts`, `app_config_https`, `outbox`, `network_wire`, `convoy_network` |
| Social | `crews_polls_355`, `crew_ride_invites_355`, `friends_parse_355`, `people_hub_355`, `push_routing_355`, `rider_score_355`, `username_rules` |
| Scenarios | `scenario_a_tunnel_blackout` … `scenario_f_indian_emergency_fallback`, `scenario_boundary_matrix`, `e2e/`, `integration/` |
| UI audits | `ui_audit_batch1`..`5` (4 path_provider tests need a device), `dark_check`, `theme_layout`, `ui_kit` |
| Diagnostics | `diag_log_355` |

## 3. Device test matrix (release safety gate)

From MASTER_AGENT_PROMPT section 6. 2-4 Android phones; one group ride and one solo ride. Record
phone model, Android version, pass/fail, notes. **Any failure in A = STOP (no Play release).**

Suggested devices: Pixel (stock Android 15/16), Samsung (One UI), Xiaomi / Redmi (MIUI/HyperOS,
aggressive battery), one budget phone (Realme / Vivo), one with a Bluetooth helmet set, one with
ANC earbuds.

| Block | Checks |
|---|---|
| **A. Safety (stop on failure)** | SOS 3 s hold sends; crash alarm test opens a 30 s countdown and riding away cancels it; potholes / speed breakers then a red light → no alarm; emergency text opens the messages app with the live link; lock-screen Medical ID; "Bike down?" on a tipped parked bike; missing-rider "Send SOS" hold; SOS with mobile data off |
| B. Alerts and audio | overspeed spoken within ~2 s; music lowers when speeding (also on Bluetooth); alerts duck / pause Spotify; a call during a ride holds normal lines and lets critical ones through; siren recording → "Ambulance / Police siren close by" after ~3 s with ANC earbuds; Siren alerts switch off → mic indicator disappears; hands-free intercom ignores wind / breath; lock-screen Talk / Mute |
| C0. Profile / Settings | Profile shows no plan and no ride history; Help has 3 rows; Send feedback with diagnostics arrives in `/admin`; Settings has no help/ask/give-way/offline-map rows; after upgrade an old "off" for help/ask nearby becomes on (check `/me`); Safety health from cockpit and Settings opens the phone check and its fix buttons open the right system pages (Pixel, Samsung, Xiaomi); a finished trip's offline map is deleted after 7 days and a past trip still shows its map online |
| C. Group | roles; trip head can only change settings; pillion seat on 2 phones with one "I'm OK" answering for both; 3D bikes rotate correctly light/dark; ride chat quick actions spoken, typing hidden while moving; Navigate opens Google Maps two-wheeler and CoRoute keeps running; map search and pasted `maps.app.goo.gl` link; Share to CoRoute from Google Maps; bike details asked only once |
| D. Social and notifications | friend request in People > Requests; crew invite; crew ride invite with the app killed → push → invitation screen; admin push with image on its channel; per-kind opt-out works |
| E. Play-specific | no prices anywhere in the app; Google in-app review card from Settings > Rate CoRoute (Play-installed build only); Diagnostics → Send logs appears in `/admin` |
| F. Domain fallback | block `coroute.devmonks.space` on the phone → app falls back to DuckDNS |
| G. Resilience (server) | stop the live node mid-ride → takeover, riders reconnect, SOS still delivered; 30-minute soak; restore drill |

## 4. Regression checklist per release

Before tagging a release:

- [ ] `cd gateway && npm ci && npm test` all pass (flaky suites pass alone).
- [ ] `flutter pub get && flutter analyze && flutter test` (only known device-only failures).
- [ ] `dart run tool/play_policy_scan.dart` → 0 hits.
- [ ] `node deploy/gen_caddy_routes.js --check` → no UNCLASSIFIED route.
- [ ] Version bumped (`pubspec.yaml` next unused build; gateway `package.json`); `SHA256SUMS.txt` updated.
- [ ] Gradle release build compiles; APK installs; smoke: sign in, solo ride, SOS hold screen opens
      (cancel), settings open.
- [ ] Device gate A passes on ≥ 2 phones; B–F as relevant to the change.
- [ ] Old-app compatibility: a previous build (3.54/3.55) signs in and joins via the legacy host.
- [ ] HELLO features unchanged or extended (never removed without a compatibility plan).
- [ ] Feature switches: new ids present; locked safety ids on; removed ids gone (`hornAlert`).
- [ ] Access mode respected: free mode shows no plan UI; paid mode shows neutral messages only.
- [ ] Privacy texts (`privacy.html`, `privacy-and-security.html`, `terms.html`) match behaviour
      changes (see the compliance pack findings).
- [ ] Website checks on both hosts (deployment guide §3 step 5).
- [ ] Release notes and FEATURE_STATUS updated.

## 5. Play pre-launch report handling

Google Play runs automated tests (crawler on real devices) for every upload to a testing track.

1. Upload the AAB to **Internal testing** first; wait for the pre-launch report (usually under an hour).
2. **Stability**: any crash or ANR in the report is a blocker. Get the stack from Play Console,
   match it with `CrashLog.kt` entries in a diagnostics log if possible, fix, re-upload with the
   next build number.
3. **Accessibility** warnings (touch target, contrast, labels): fix those on safety screens (SOS,
   crash alarm, Medical ID) before production; others go to the backlog with the UX naming guide.
4. **Security and trust** (e.g. cleartext, exported components, outdated libraries): fix before
   production.
5. **Performance** (startup, frozen frames): compare with the previous build; investigate
   regressions > 20 %.
6. The crawler cannot sign in unless credentials are provided: give the test account in Play
   Console (Pre-launch report settings) so screens behind sign-in are crawled. Use a test account
   that is **not** in any real group, and never let the crawler raise a real SOS to real contacts
   (set its emergency contact to a team number).
7. Record the report outcome in the release notes. Also watch **Android vitals** after rollout:
   advance the staged rollout (10 % → 50 % → 100 %) only with crash-free ≥ 99.5 % and no SOS /
   crash issue in 48 h (Play bad-behaviour thresholds: 1.09 % crashes, 0.47 % ANR).
