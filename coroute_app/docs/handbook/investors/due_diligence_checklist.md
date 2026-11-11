# Due diligence checklist

What an investor can review today, and what is still pending. Status as of 11 Nov 2026. "Ready" means the item exists and can be shown; it does not mean it has been externally audited. Paths are relative to the repository root (`/home/claude/app`).

Legend: **Ready** · **Partial** (exists, with a known gap) · **Pending** (not done) · **Owner** (company or founder documents only the owner can provide).

---

## 1. Product and code

| Item | Status | Evidence / notes |
|---|---|---|
| Android app source (Flutter + Kotlin native) | Ready | `lib/`, `android/`; `pubspec.yaml` version 3.55 line |
| Gateway source (Node.js) | Ready | `gateway/src/` |
| Website, web admin, operator console | Ready | `gateway/public/` (site, `/admin`, `/operator`); website live at https://coroute.devmonks.space |
| Feature inventory with status per feature | Ready | `docs/FEATURE_STATUS.md` (stable / needs device check / pending, with admin switch ids) |
| Release notes | Ready | `docs/V3_55_RELEASE.md`; 3.56 feature docs in `docs/features_355/` (access modes, operators, web payments, Play payments policy, SOS SMS, notifications) |
| Roadmap with effort estimates and owner decisions | Ready | `docs/NEXT_RELEASE_PLAN_v3.56.md` |
| Competitor analysis | Ready | `docs/COMPETITOR_ANALYSIS_2026-11.md` (desk research, sources listed) |
| Design system | Ready | `docs/DESIGN_SYSTEM_v3.55.md` (tokens, contrast table, Manrope) |
| iOS app | Pending | `ios/` folder exists; app not built or published; timing is owner decision D16 |
| Source code ownership / IP assignment from every contributor | Owner | **[OWNER TO PROVIDE]** assignment agreements; list of third-party code and licences |
| Open-source licence inventory | Pending | Generate from `pubspec.lock` and `gateway/package-lock.json` before diligence |

## 2. Testing and quality

| Item | Status | Evidence / notes |
|---|---|---|
| Gateway automated tests | Ready | 904 / 904 passing at the last full documented run (9 Nov 2026, `docs/NEXT_RELEASE_PLAN_v3.56.md`, `docs/FEATURE_STATUS.md`). 3.56 adds suites such as `operators_356` (16 tests), `access_mode_356`, `web_payments_security_355` (20 tests). 155 files in `gateway/test/`. **Re-run the full suite and record the new total before sharing.** |
| App logic tests (pure Dart) | Partial | 238 `*_test.dart` files in `test/`. Pure-logic tests run with plain `dart` (e.g. sensor safety 34 / 34; crash detector 32, false-positive guards 6, advanced crash 14). Flutter widget and service tests could not run in the build environment (no engine): **run `flutter test` on a build machine.** |
| Static analysis | Ready | Analyzer clean per release docs |
| Browser smoke tests | Ready | `tool/web_admin_smoke.js`, `tool/operators_smoke.js` (Playwright) |
| Safety scenario review | Ready | `docs/SAFETY_SCENARIO_REVIEW_v3.55.md`: 11 defects found and fixed, each with a regression test |
| Crash false-alarm review | Ready (synthetic) | `docs/features_355/sensor_safety.md` §7: scenario matrix on synthetic sequences; device tuning pending |
| Siren detection and voice cleanup lab results | Ready (synthetic) | `docs/features_355/sound_awareness_and_intercom.md`; real roads not yet tried |
| Test plan, release gates, safety invariants, traceability | Ready | `docs/testing/` |
| Feature audits and field validation checklists | Ready | `docs/FEAT-0x_*` (analysis, audit report, test plan, field validation) |
| **Real-device validation** of sensor, audio, lock-screen and push features | **Pending** | Every "Needs device check" row in `FEATURE_STATUS.md`; consolidated device gate in `docs/DEPLOY_PROMPT_v3.55.md`; device matrix in `docs/SAFETY_DEVICE_TESTS.md` |
| **Native Kotlin compile of the 3.55 audio / telephony code** | **Pending** | Not compiled in the build environment (no Android SDK) |
| Load and failover test | Pending | Two-VM drill and 30-minute soak (`gateway/scripts/load_convoy_ws.js`) to measure the live-rider cap (estimate 200–700) |
| Crash / ANR baseline | Pending | Needs 2–4 weeks of Play vitals after launch |

## 3. Security

| Item | Status | Evidence / notes |
|---|---|---|
| Payments security review | Ready | `docs/features_355/web_payments_security.md`: threats, mitigations, tests (atomic order claim, amount re-check, HMAC webhooks, replay protection, coupon brakes) |
| Web admin security design | Ready | `docs/features_355/web_admin.md` (master-admin only, strict CSP, session-only tokens, idle timeout, masked secrets) |
| Operator console privacy and audit | Ready | `docs/features_355/operators.md` (no phone / e-mail / coordinates in roster, reports or CSV; audited SOS contact views) |
| Secrets management | Partial | OCI Vault + tmpfs secrets on the VMs (`docs/PRODUCTION_TWO_VM_RUNBOOK.md`); **secrets rotation (P8) pending** before partners get accounts |
| Encrypted backups | Ready | Backup encryption key and Object Storage backups (runbook) |
| External penetration test | Pending | **[OWNER TO COMMISSION]** before or soon after launch |
| Incident response / breach notification process | Pending | Needed for DPDP; **[OWNER TO WRITE]** |

## 4. Privacy and policies

| Item | Status | Evidence / notes |
|---|---|---|
| Privacy policy (public) | Ready | https://coroute.devmonks.space/privacy (`gateway/public/privacy.html`): no ads, no third-party analytics or tracking SDKs, no sale of data, 90-day route deletion |
| Privacy and security page | Ready | `gateway/public/privacy-and-security.html` |
| Terms of use (public) | Ready | `gateway/public/terms.html`: "an aid to group coordination, not a safety device", "as is", limitation of liability |
| Account deletion | Ready | In the app, and `gateway/public/delete-account.html` |
| Play permissions and Data safety mapping | Ready | `docs/PLAYSTORE_PERMISSIONS.md` (last reviewed 6 Nov 2026) |
| Play payments policy compliance | Ready (code) | `docs/features_355/play_payments_policy.md`; `tool/play_policy_scan.dart` must print 0 hits before each release |
| Store listing text and graphics | Ready (draft) | `/home/claude/store/out/play_assets/` (listing text written to Play listing policy) |
| **DPDP Act 2023 update** (consent records, purpose limits, erase) | **Pending** | Plan item P9; required before partner, insurance or fleet data sharing |
| **Legal review of terms, privacy policy and safety-liability wording** | **Pending** | **[OWNER: engage counsel]** |
| SMS sender registration (DLT) for server SOS texts | Pending | Needed for MSG91 in India; **[OWNER]** |
| Grievance officer / contact as required by Indian IT rules | Owner | **[OWNER TO CONFIRM]** |

## 5. Launch readiness

| Item | Status | Notes |
|---|---|---|
| Google Play developer account and listing | Pending | Listing text and graphics drafted |
| Closed testing and production rollout | Pending | Plan gate P2 |
| Firebase project (push) | Pending | Plan gate P6 |
| Production deploy of the latest build | Pending | `docs/DEPLOY_PROMPT_v3.55.md` |
| Razorpay live account (website) | Owner | Business details, refund and contact pages required by Razorpay (`docs/features_355/web_payments.md` § Owner setup) |
| SMTP sender (receipts, operator e-mails) | Owner | Domain SPF / DKIM (`docs/features_355/purchase_email.md`) |

## 6. Company and finance (owner documents)

| Item | Status |
|---|---|
| Certificate of incorporation, MoA / AoA (or LLP agreement) | **[OWNER TO PROVIDE]** |
| Cap table, ESOP pool, prior instruments (SAFEs, notes) | **[OWNER TO PROVIDE]** |
| Founder agreements, vesting, IP assignment | **[OWNER TO PROVIDE]** |
| GST registration (required for B2B invoicing, partner and operator billing) | **[OWNER TO PROVIDE]** |
| PAN / TAN, bank account, statutory filings | **[OWNER TO PROVIDE]** |
| Trademark search / filing for "CoRoute" | **[OWNER TO PROVIDE]** |
| Domain ownership (`devmonks.space`) | **[OWNER TO CONFIRM]** |
| Financial statements, burn, runway | **[OWNER TO PROVIDE]**; projections in `financial_model_template.xlsx` once inputs are filled |
| Contracts (cloud, SMS, payment gateway, any partners) | **[OWNER TO PROVIDE]** |
| Employment / contractor agreements | **[OWNER TO PROVIDE]** |
| Insurance (professional liability / cyber) | **[OWNER TO DECIDE]** given the safety nature of the product |

## 7. Data room structure (suggested)

```
01_Company/          incorporation, cap table, agreements
02_Product/          one_pager.pdf, investor_memo.pdf, FEATURE_STATUS.md, V3_55_RELEASE.md, roadmap
03_Technology/       architecture (memo appendix B), runbook (no secrets), test reports, security reviews
04_Privacy_Legal/    privacy policy, terms, Play permissions, DPDP plan, counsel opinions
05_Market/           competitor analysis, sourced market data
06_Financials/       financial_model_template.xlsx (filled), statements, burn
07_Traction/         weekly updates, KPI exports (from launch)
```

Never put secrets in the data room: no `.env` files, keys, credentials documents or database passwords.
