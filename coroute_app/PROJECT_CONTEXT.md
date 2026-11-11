# CoRoute: full project context

The single starting point for any human or AI agent working on CoRoute. Rewritten 11 Nov 2026
(keeps the still-valid content of the Nov 10 version). If something here disagrees with the code,
the code wins; fix this file.

**Rules for agents:** never commit unless the owner asks; never print or copy secrets
(`CLUSTER_CREDENTIALS.md`, `.env`, `android/key.properties`, keystores, FCM JSON, SMTP / SMS /
Razorpay keys); never ship anything that could stop SOS, crash detection, emergency texts or the
lock-screen Medical ID; the Play app must contain no prices, payments, coupons or buying words
(`dart tool/play_policy_scan.dart` = 0 hits); ask the owner, never invent, for Firebase values,
SMTP, SMS/DLT, Razorpay, Play Console access, test accounts.

---

## 1. What CoRoute is

A motorcycle **group and solo riding safety** platform for India.

- **Android app** (Flutter, package `space.devmonks.coroute_app`): live group map, SOS (hold 3 s),
  phone-based crash detection with a 30 s countdown, emergency texts, lock-screen Medical ID,
  group intercom, siren alerts for riders who cannot hear outside, riding roles
  (Lead / Middle / Sweeper), missing-rider checks, road hazards, offline maps, Ride Guardian links
  for family, help from nearby riders of other groups, friends, crews, polls, crew ride invites,
  private rider score and public leaderboards.
- **Gateway** (Node.js 22, Express + ws) on two OCI VMs behind an OCI Network Load Balancer and
  Caddy (TLS); **Oracle Autonomous DB** (Always Free) via ORDS SODA, only from the gateway, schema
  `COROUTE` (never ADMIN).
- **Website** served by the gateway: public site, rider shop (`/signin`, `/plans`, `/account`,
  `/receipt`; Razorpay), web admin (`/admin`), operator console (`/operator`), live emergency
  pages (`/e/:token`), Ride Guardian (`/watch`), offers board (`/updates`), leaderboards.
- Business model: Community (free: solo rides, joining any ride, every safety feature); paid
  **Small Group (2–6)** and **Large Group (7–12)** let a rider host group rides; bought **only on the
  website**. Admin-selectable **access mode** (Paid / Free for everyone / Free up to limits).
  Operators (tour operators, clubs, rental and corporate fleets) get a web console.
- Status: **pre-launch** (no Play production release yet). Target users: licensed riders 18+.

## 2. Owner decisions log

Sources: [docs/V3_55_RELEASE.md](docs/V3_55_RELEASE.md) (§1, 1b–1g), [docs/SETTINGS_MINIMAL_v3.55.md](docs/SETTINGS_MINIMAL_v3.55.md),
[docs/features_355/access_modes.md](docs/features_355/access_modes.md), [docs/features_355/play_payments_policy.md](docs/features_355/play_payments_policy.md),
[docs/FEATURE_STATUS.md](docs/FEATURE_STATUS.md).

| Date (2026) | Decision |
|---|---|
| Nov 7 | Riding roles **Lead / Middle / Sweeper**; exactly one Lead, at most one Sweeper; trip owner keeps owner rights whatever the role. **Automatic roles off by default**; an automatic lead gets no management rights. |
| Nov 7 | **Guest mode removed completely** (`/auth/guest` → 410). |
| Nov 7 | **No sample or mock data anywhere**; website numbers are real, privacy-rounded. |
| Nov 7 | Admin **feature switches** for every feature; SOS, crash detection, emergency texts, Medical ID **locked on**; unknown = on. |
| Nov 7 | Admin "Change plan" creates **real memberships** (₹0 ledger, audited). |
| Nov 9 | Sirens are for riders who **can't hear outside**; "Tell my group" removed. |
| Nov 9 | **Medical info: no consent switch.** Shown on lock screen and to responders (group, guardians, accepted outside helper) only while an alert is open. |
| Nov 9 | **Emergency contact shared with an accepted outside helper** during an open alert: yes. |
| Nov 9 | Missing-rider check has a separate **Send SOS (hold)**. |
| Nov 9 | **Taps while moving**: voice + chip while moving, full card when stopped. |
| Nov 9 | **One member with a plan hosts**; others join free. |
| Nov 9 | Naming: **Trip owner** (created the trip), **Trip head** (= **trip settings only**: cannot remove riders or end the trip; choosing one does not make them Lead), **Lead** (riding role). |
| Nov 9 | Admin Warn: required text ≤ 280 characters. Place review after the ride (≤ 2 places, skippable). |
| Nov 9 | Speed: app was not under-reading (speedometers over-read); **no speedometer offset**. |
| Nov 9 | Top rider score level **Ace Rider**. Website "riders" = registered riders with ≥ 1 completed ride. |
| Nov 9 | Own domain **`coroute.devmonks.space`**; `coroute.duckdns.org` kept ≥ 6 months. |
| Nov 9 late | **Siren alerts get a rider switch, on by default** ("Listens on your phone during rides. Nothing is recorded."). |
| Nov 9 late | **Upgrade only, no downgrade** while a paid plan runs (409 `DOWNGRADE_NOT_ALLOWED`); admin exempt. |
| Nov 10 | **No horn alerts** (detector, setting, card and switch `hornAlert` removed). |
| Nov 10 | **Payments on the website only**; the Play app is consumption-only (no prices, payments, coupons, steering). |
| Nov 11 | **Access modes** configurable in the web admin (Paid / Free for everyone / Free up to limits, scheduled change in IST); app shows no plans, features or payments. Safety never gated. |
| Nov 11 | **Minimal settings**: safety always on with no switch (crash detection, SOS, emergency texts, lock-screen ride and Medical ID, check-ins, no-signal ahead, break reminder, road warnings, auto re-route, voice cleanup, keep screen on). |
| Nov 11 | **Help nearby riders / Ask nearby riders to help me: always on** (no switch). Give-way side fixed Automatic; safety report in score fixed on; offline maps automatic (7 days after trip, 300 MB). |
| Nov 11 | **Minimal Profile**: top box, My bikes, Emergency contact & Medical ID, score + Leaderboard; **Help = Send feedback, Rate CoRoute, Privacy & terms (always present)**; Account = Sign out, Delete account. Your plan and ride history removed from Profile. |
| Nov 11 | Push kinds with channels and opt-outs; **Partner perks off by default**; opt-in Offers e-mails with unsubscribe and suppression. |
| Nov 11 | Operators / clubs console (switch `operators`). |
| Release prompt | `REDIRECT_LEGACY_HOST=true` for this release; raise HSTS on the new domain after a stable week. |

## 3. Current state (11 Nov 2026)

| Area | State |
|---|---|
| Versions | pubspec `3.55.0+10022`; gateway `3.55.0`; next Play upload uses the next unused build (MASTER_AGENT_PROMPT plans `+10023`) |
| Gateway tests | **1,091 / 1,091 pass** (`npm test`, run 11 Nov 2026) |
| Play policy scan | **0 hits** (11 Nov 2026) |
| Flutter tests | ~2,176 cases in 238 files; last recorded full run 2,142 / 2,146 (Nov 10; 4 device-only `ui_audit` tests) |
| Production | Nov 10 record: v3.55 deployed (VM2 then VM1), APK/AAB build 10019 artifacts, domain migrated with DuckDNS compatibility. The 3.56 work below (web shop, access modes, operators, push kinds, minimal profile ...) is **in the working tree, not yet deployed** per MASTER_AGENT_PROMPT. |
| Kotlin | Several 3.55/3.56 Kotlin files have **never been compiled** (AccelStream, TtsChannel, MediaVolumeGuard, PhoneCallChannel, RideNotification, PushChannel, CoRouteMessagingService, CrashLog, SafetyChannel, SmsChannel, InAppReviewChannel, NavHandoffChannel, ShareInActivity, MainActivity) |

**Built and tested in code** (gateway tests and/or pure Dart tests): roles and automatic roles,
feature switches, plans/memberships, access modes, website shop and payment security, operators,
push and campaigns, offer e-mails, SOS SMS (phone + server), diagnostics logs, social (usernames,
friends, crews, polls, ride invites), rider score and leaderboards, road hazards and place
reviews, heritage places, bike/pillion swap and pillion seat, live settings, minimal settings
migrations, domain fallback, two-node mirror and job leases.

**Needs device check** (FEATURE_STATUS has 77 such mentions): crash detection thresholds,
rider-down, road surface detection, siren detection and audio routing (ANC, helmet sets), music
ducking / lowering, call-aware alerts, lock-screen Talk/Mute, full-screen SOS, Safety health fix
buttons per OEM, missing-rider Send SOS, chips while moving, push with the app killed, domain
fallback, speed vs GPS app, pillion flows, 3D bike markers, Navigate hand-off, Share to CoRoute.
The release gate is MASTER_AGENT_PROMPT §6 (block A failure = no release).

**Pending (not code)**: commit the working tree; Flutter + Gradle build; device gate; deploy;
failover drill and 30-min soak (sets `LIVE_RIDER_CAP`); restore drill; Object Storage for photos
and APKs; **rotate JWT secret and DB password (old values in git history)**; **owner regenerates
the DuckDNS token (in git history, `setup_new_vm.sh`)**; **move `vm_provision_ssh.key` off VM1**;
Firebase project; SMTP; SMS provider + DLT; Razorpay webhook on the new host; Play Console
(closed test 12 testers × 14 days, data safety, permission declarations, video); legal review of
the website policies (privacy, terms, deletion and the new `/refunds` were brought in line with the app on
Nov 11; `/security` + `/.well-known/security.txt` added); grievance officer name; set `SUPPORT_EMAIL` /
`SECURITY_CONTACT` to role addresses (no built-in default any more).

## 4. Repository map

| Path | What |
|---|---|
| `lib/` | Flutter app: `core/` (config, theme tokens `core/theme/app_palette.dart`, design kit `core/ui/design_kit.dart`, l10n), `data/` (services, local stores, models), `domain/` (pure logic), `presentation/` (screens) |
| `android/app/` | Kotlin platform channels, manifest, Gradle |
| `test/` | Dart tests |
| `gateway/src/` | Gateway modules (`app.js` wiring, `config.js` env, `ws.js` sockets, `convoys.js` rooms, `timeline.js`, `safety_network.js`, `mirror.js`, `job_lease.js`, `oracle/repo.js` ...) |
| `gateway/public/` | Website, `/admin`, `/operator`, live and guardian pages, APKs + `SHA256SUMS.txt`, `.well-known/assetlinks.json` |
| `gateway/test/` | Gateway tests |
| `gateway/deploy/` | Caddyfiles (`caddy/Caddyfile.vm1`, `.vm2`), systemd units, setup / hardening scripts, `RUNBOOK.md`, `route_split.md`, `VM_OPERATIONS_LOG.md`, `gen_caddy_routes.js` |
| `gateway/scripts/` | `init_db.js`, `backup_restore.js`, `load_convoy_ws.js` |
| `tool/` | `play_policy_scan.dart`, `web_admin_smoke.js`, `operators_smoke.js`, `diag/analyze_logs.js`, `map_bikes/`, `design_contrast.py` |
| `docs/` | Release notes, feature docs, runbooks, testing docs, manuals, **handbook** |
| `store/` | Play listing text and graphics |
| `release/` | Release artifacts per version |
| `design/` | Design material |

## 5. How to build, test and deploy (pointers)

```bash
# app
flutter pub get && flutter analyze && flutter test
flutter build appbundle --release          # no COROUTE_API define (keeps the DuckDNS fallback); FCM values as -P gradle properties
flutter build apk --release --split-per-abi

# policy
dart tool/play_policy_scan.dart            # must print 0 hits

# gateway
cd gateway && npm ci && npm test
ORACLE_SODA_URL=memory ORACLE_USER=x ORACLE_PASSWORD=x JWT_SECRET=$(openssl rand -base64 48) npm start   # local, no DB
```

- Development guide: [docs/handbook/technical/development_guide.md](docs/handbook/technical/development_guide.md)
- Release / deploy / Play: **[docs/MASTER_AGENT_PROMPT_v3.55.md](docs/MASTER_AGENT_PROMPT_v3.55.md)** (replaces DEPLOY_PROMPT, RELEASE_FINISH_PROMPT, NEXT_AGENT_PROMPT, kept as background)
- Operations: [docs/handbook/technical/deployment_and_operations.md](docs/handbook/technical/deployment_and_operations.md), [docs/PRODUCTION_TWO_VM_RUNBOOK.md](docs/PRODUCTION_TWO_VM_RUNBOOK.md), [gateway/deploy/RUNBOOK.md](gateway/deploy/RUNBOOK.md)

## 6. Domains and infrastructure

| Item | Value |
|---|---|
| Canonical origin | `https://coroute.devmonks.space` (`PUBLIC_ORIGIN`) |
| Legacy origin | `https://coroute.duckdns.org` (`LEGACY_ORIGINS`), fully served for installed apps ≥ 6 months; website pages 301 when `REDIRECT_LEGACY_HOST=true` (never `/api`, `/ws`, `/.well-known`, `/e/`, `/watch`) |
| App gateway | default `coroute.devmonks.space`, automatic fallback to DuckDNS |
| Servers | VM1 `GATEWAY_ROLE=live` (rooms, sockets, SOS), VM2 `GATEWAY_ROLE=web` (website, payments, admin, mirror copy); OCI NLB (health `/api/health/live`, VM1 primary, VM2 backup) |
| TLS | Caddy, ACME DNS-01 through DuckDNS for both names; HSTS 300 s on the new domain until raised |
| Database | Oracle Autonomous DB, Hyderabad, schema `COROUTE`, ACL = the two VMs |
| Secrets | OCI Vault → `coroute-secrets.service` → `/run/coroute/secrets.env` (tmpfs); non-secret settings in `/etc/coroute/gateway.env`; Android signing in `android/key.properties` (git-ignored). **None in this repository.** |
| Object Storage | backups (encrypted), review photos, diagnostics logs, push images (PAR URLs) |
| External services | FCM (push), SMTP (mail), MSG91 / Twilio (SOS SMS, DLT), Razorpay (website), Google Sign-In, OSM Photon / Nominatim / OSRM / Overpass, Open-Meteo |
| Admin accounts | `users.role = MASTER_ADMIN`; first from `BOOTSTRAP_ADMIN_EMAILS`, then `PATCH /api/admin/users/:id/role` |

## 7. Where every document lives

**Handbook** (start here for any audience): [docs/handbook/README.md](docs/handbook/README.md)

| Pack | Index |
|---|---|
| Investors | [docs/handbook/investors/00_README.md](docs/handbook/investors/00_README.md) |
| Operators and partners | [docs/handbook/operators/00_README.md](docs/handbook/operators/00_README.md) |
| Users and support | [docs/handbook/users/00_README.md](docs/handbook/users/00_README.md) |
| Technical | [architecture](docs/handbook/technical/architecture.md), [API](docs/handbook/technical/api_reference.md), [data model](docs/handbook/technical/data_model.md), [mobile app](docs/handbook/technical/mobile_app.md), [development](docs/handbook/technical/development_guide.md), [deployment & ops](docs/handbook/technical/deployment_and_operations.md), [incident & SOS ops](docs/handbook/technical/incident_response_and_sos_ops.md), [security](docs/handbook/technical/security_overview.md), [QA](docs/handbook/technical/qa_test_plan.md), [glossary](docs/handbook/technical/glossary.md) |
| Compliance | [privacy pack](docs/handbook/compliance/privacy_compliance_pack.md), [Play](docs/handbook/compliance/play_store_compliance.md), [consent & retention](docs/handbook/compliance/consent_and_retention_register.md), [policies index](docs/handbook/compliance/policies_index.md) |

**Engineering source docs** in `docs/`:

| Document | Purpose |
|---|---|
| [V3_55_RELEASE.md](docs/V3_55_RELEASE.md) | Every 3.55 request, how it was done, compatibility notes, owner decisions |
| [FEATURE_STATUS.md](docs/FEATURE_STATUS.md) | Every feature with status and admin switch id |
| [MASTER_AGENT_PROMPT_v3.55.md](docs/MASTER_AGENT_PROMPT_v3.55.md) | Release agent prompt (build, deploy, device gate, Play) |
| [SAFETY_SCENARIO_REVIEW_v3.55.md](docs/SAFETY_SCENARIO_REVIEW_v3.55.md) | Real-time safety scenarios, defects fixed, open risks |
| [SETTINGS_MINIMAL_v3.55.md](docs/SETTINGS_MINIMAL_v3.55.md), [SETTINGS_LIVE_AUDIT_v3.55.md](docs/SETTINGS_LIVE_AUDIT_v3.55.md) | Settings decisions, migrations, live-apply audit |
| [UX_NAMING_GUIDE_v3.55.md](docs/UX_NAMING_GUIDE_v3.55.md), [DESIGN_SYSTEM_v3.55.md](docs/DESIGN_SYSTEM_v3.55.md) | Naming and design system |
| [features_355/](docs/features_355/) | One doc per feature area (access modes, operators, payments, push, SOS SMS, diagnostics, audio, sensors, social ...) |
| [PRODUCTION_TWO_VM_RUNBOOK.md](docs/PRODUCTION_TWO_VM_RUNBOOK.md), [DOMAIN_MIGRATION_devmonks.md](docs/DOMAIN_MIGRATION_devmonks.md), [SERVER_LOAD.md](docs/SERVER_LOAD.md), [BATTERY.md](docs/BATTERY.md) | Operations |
| [PLAYSTORE_PERMISSIONS.md](docs/PLAYSTORE_PERMISSIONS.md), [PLAY_STORE_RELEASE_CHECKLIST.md](PLAY_STORE_RELEASE_CHECKLIST.md) | Play |
| [testing/](docs/testing/) | Layered test plan, release gates, safety invariants, traceability |
| [NEXT_RELEASE_PLAN_v3.56.md](docs/NEXT_RELEASE_PLAN_v3.56.md) | Next release plan with open decisions D1–D18 |
| [COMPETITOR_ANALYSIS_2026-11.md](docs/COMPETITOR_ANALYSIS_2026-11.md) | Competitors (Trilyt etc.) |
| [PENDING_SAFETY_FEATURES_ROADMAP.md](docs/PENDING_SAFETY_FEATURES_ROADMAP.md) | Safety roadmap |
| [manuals/](docs/manuals/) | Older user and investor PDF manuals (superseded by the handbook packs) |
| [PRODUCTION_PLAN.md](PRODUCTION_PLAN.md) | Original architecture, audit and rollout plan |

## 8. Open decisions

From MASTER_AGENT_PROMPT §9, FEATURE_STATUS and the handbook:

- Access mode at launch and the free limits; whether plan status is hidden in paid/hybrid mode too.
- Launch prices (code defaults are configuration, not a decision).
- Partner perks default (currently off).
- SMS provider (MSG91 or Twilio) and DLT timing.
- HSTS raise date for `coroute.devmonks.space`.
- iOS / TestFlight timing (D16).
- Refund criteria and reply / settlement times for `/refunds` (page live, values [OWNER TO FILL]); grievance officer; role e-mail addresses for `SUPPORT_EMAIL` / `SECURITY_CONTACT`.
- DPDP review of the always-on items (help/ask nearby, score report, medical info without consent switch).
- v3.56 decisions D1–D18 in [docs/NEXT_RELEASE_PLAN_v3.56.md](docs/NEXT_RELEASE_PLAN_v3.56.md#open-owner-decisions)
  (helmet button, Wear OS, ERSS 112 outreach, weather source, events above 12 riders, B2B pricing ...).

## 9. Next release

[docs/NEXT_RELEASE_PLAN_v3.56.md](docs/NEXT_RELEASE_PLAN_v3.56.md): v3.56.0 quick safety wins
(helmet / headset button for talk and SOS, 112 one-tap fallback, route weather and road alerts,
pre-ride bike check, more Indian languages for safety screens), v3.56.x group and growth (ride
planner, Wear OS, offline phone-to-phone voice, albums, events, club pages, challenges, referrals),
v3.57 business and platform (partners, insurance, fleets, ERSS). Prerequisites P1–P9: v3.55 device
gate, Play production, crash/ANR baseline, metrics baseline, two-VM drill and soak, Firebase,
Object Storage, secrets rotation, DPDP privacy update. Some 3.56 items (operator console, access
modes, web shop) were brought forward and are already built.
