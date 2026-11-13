# Round 6 gateway notes (for the lead)

Gateway, web admin, deploy and docs work of round 6. The Flutter app, the account page, avatars, weather and the
risky-stretch module belong to the app agent and were not touched.

## 1. Clean-ups

| # | Item | Result |
|---|---|---|
| a | Real values in tracked files | Moved to the untracked inventory. New `deploy/_inventory.py` and `deploy/_inventory.sh`; scripts stop with a clear message when a value is missing. What to rotate and the optional `git filter-repo` steps: `docs/security/GIT_HISTORY_CLEANUP.md` |
| b | Route split | Every served route is classified (557 at the time of writing: 88 LIVE, 469 WEB). The check boots the real app. `release.sh` stops on an unclassified route |
| c | `.env.example` | Un-ignored, placeholders only, every variable documented (about 60 were missing). Test fails on a new undocumented variable |
| d | Compare-and-replace | **Scalars alone were not safe.** Fixed with a revision token (`casRev`). See section 2 |
| e | `LIVE_RIDER_CAP` | Config only, default unset (0 = off), documented with the owner-facing suggestion (2500 on the micros), tested |
| f | TODO / follow-ups | None in `src`. List: `docs/quality/GATEWAY_FOLLOWUPS.md` |

## 2. Compare-and-replace review (important)

The precondition had become "test every top-level scalar of the document the caller read". Three kinds of
concurrent change pass that test unnoticed:

1. a change inside a nested array or object;
2. a top-level key that the other writer **added**;
3. a plain replace that changes no scalar.

| Caller | Was it exposed? | What could happen |
|---|---|---|
| Job lease (`job_lease.js`) | **Yes** | The hand-back request adds `wantedBy` / `wantedAt`. The holder's renew overwrote it, so a job that prefers the live node (`convoy-auto-end`, `guardian-push`) never moved back from the web node |
| Coupons (`repo._couponAtomic`, `_writeCoupon`) | **Yes** | Two holds in the same millisecond (same `updatedAt`), or a hold release (no scalar changes): the second write replaced the first. A coupon with one use left could be held by two orders |
| Order claim (`repo.claimRazorpayOrder`) | Partly | Two claims: safe (`status` changes). A refund recorded in the nested `refunds` list between the read and the claim was overwritten |
| Session refresh (`sessions.refresh`) | No | `refreshHash`, `refreshCounter`, `revokedAt` are scalars that exist from creation |
| Ride lock codes (`email_codes.js`) | Not a caller | Does not use compare-and-replace. Its tries counter is not atomic: follow-up F1 |
| E-mail / push campaigns, mail log, rider score, hosted ride counts, guardian jobs | Minor | Stats objects and recipient lists are nested; a status or cursor scalar changes in the normal paths |

**Fix (in `src/oracle/soda.js`):** every document of the compare-and-replace collections carries one scalar,
`casRev`, a unique token that changes on **every** write (insert, replace, compare-and-replace). The JSON Patch
tests it with the other scalars. Documents written before this release:

- are handled safely at once: read, compare in full, add a `casRev` with a JSON Patch `add` (changes nothing
  else), read again, then compare-and-replace on that token (three extra calls, once per old document);
- get their token from the leased job `cas-rev-seed` (3 minutes after start, then daily; 2,000 documents a run).

Collections: `leases`, `auth_sessions`, `coupons`, `subscription_config`, `guardian_subscriptions`,
`guardian_jobs`, `mail_log`, `email_studio_templates`, `email_studio_campaigns`, `email_studio_rules`,
`offer_email_campaigns`, `push_campaigns`, `rider_scores`, `hosted_ride_counts`, `business_agg`. Other collections
behave exactly as before.

`MemorySoda` now applies the same patch tests as the database instead of a deep comparison, so a test can show a
race the database would miss. `test/cas_rev_356.test.js` runs each race twice (with the token: detected; scalars
only: missed) and asserts the emitted patches. `gateway/test/soda_atomic.test.js` (the device agent's file) was
**not changed** and passes: its collection `jobs` is not a compare-and-replace collection.

Owner check after deploy: `casRev` is a new top-level field name on those documents. If the Oracle collection
rejects it, set aside the release (the first compare-and-replace would fail). It is a plain string member; no
problem is expected.

## 3. Business brain

Built: cohort retention, activation funnel, plan / coupon / campaign conversion, revenue trend, renewals due,
churn warning (rules + small logistic regression), "At risk this week" with win-back through the e-mail wizard,
best send time and "At each rider's best time" in the wizard, review list (never blocks), weekly owner summary,
Servers page. Details: `docs/intelligence/BUSINESS_ANALYTICS.md`.

## 4. Files

**New:** `gateway/src/business/{index,brain,churn_model,servers,summary}.js`, `gateway/public/admin/business.js`,
`gateway/deploy/_inventory.py`, `gateway/deploy/_inventory.sh`,
`gateway/test/{cas_rev,route_split,config_env_example,deploy_inventory,business_brain,business_churn,business_sendtime,business_signals,business_summary,business_servers}_356.test.js`,
`gateway/test/_business_helpers.js`, `docs/intelligence/BUSINESS_ANALYTICS.md` (replaces `BUSINESS_LATER.md`),
`docs/security/GIT_HISTORY_CLEANUP.md`, `docs/quality/GATEWAY_FOLLOWUPS.md`, this file.

**Changed (gateway/src):** `app.js` (business mount, app-open hook, `cas-rev-seed` job, `coroute_node_info`
metric, the "ROUND 6 app-agent mounts go here" block), `oracle/soda.js`, `oracle/memory_soda.js`, `field_crypto.js`,
`metrics.js`, `email_marketing.js` (`bestTime`), `templates.js` (`owner_weekly_summary`), `backup_jobs.js`
(`ops_status`).

**Changed (web admin):** `index.html` (Business group, Servers), `admin.css`, `console.js` (Settings > Weekly
summary), `email_wizard.js` (best-time choice, prefill with usernames).

**Changed (deploy):** `route_split.md`, `gen_caddy_routes.js`, `release.sh`, `caddy/Caddyfile.vm1` (regenerated,
`VM2_PRIVATE_IP` placeholder), `caddy/Caddyfile.vm2`, `setup_node.sh`, `setup_new_vm.sh`, `setup_vm2.sh`,
`harden_security.sh`, `audit_security.sh`, `auto_provision_ampere.py`, `smart_free_provisioner.py`,
`update_adb_acl.py`, `inventory.example.env`, `.env.example`, `Caddyfile.loadbalanced`, `valhalla/docker-compose.yml`,
`VM_OPERATIONS_LOG.md`, `PLAY_STORE_CHECKLIST.md`. Root `.gitignore` (un-ignores `gateway/deploy/.env.example`).

**Changed (docs):** `docs/handbook/technical/api_reference.md`, `docs/features_355/web_admin.md`,
`docs/intelligence/ROAD_AND_SAFETY_INTELLIGENCE.md`; placeholders for real addresses / paths in
`docs/PRODUCTION_TWO_VM_RUNBOOK.md`, `docs/MASTER_AGENT_PROMPT_v3.55.md`, `docs/DEPLOY_PROMPT_v3.55.md`, older
prompt and FEAT docs, `DAILY_LOG_ANALYSIS_REPORT.md`, `UX_QA_AUDIT_REPORT.md`, `PLAY_STORE_RELEASE_CHECKLIST.md`,
`design/figma/export_showcase.js`.

## 5. New environment variables (all optional; documented in `deploy/.env.example`)

| Variable | Default | Meaning |
|---|---|---|
| `BUSINESS_ANALYTICS` | on | off = no nightly job, no app-open counter, no weekly summary |
| `BUSINESS_PAGE_SIZE` | 200 | documents per page in the nightly job |
| `BUSINESS_PAGE_PAUSE_MS` | 40 | pause between pages |
| `BUSINESS_MAX_RIDERS` | 100000 | riders with rides held in memory during the job |
| `BUSINESS_MAX_USERS` | 300000 | accounts scanned per night |
| `PEER_METRICS_URL` | derived from `MIRROR_PEER_URL` | the other node's `/metrics` for the Servers page |
| `NODE_MEMORY_MB` | 1024 | RAM of the VM, for the memory colour |

For the Servers page to show the other node: on **each** VM add the other VM's private IP to `METRICS_ALLOW`
(for example `METRICS_ALLOW=loopback,<peer-private-ip>`), or set the same `METRICS_TOKEN` on both.

Inventory (`deploy/inventory.local.env`, new keys): `OCI_TENANCY_OCID`, `OCI_COMPARTMENT_OCID`, `OCI_REGION`,
`OCI_AVAILABILITY_DOMAIN`, `OCI_VCN_OCID`, `OCI_SUBNET_OCID`, `OCI_ADB_OCID`, `OCI_ARM_IMAGE_OCID`,
`OCI_X86_IMAGE_OCID`, `OCI_CONFIG_FILE`, `VM_SSH_PUBLIC_KEY_FILE`, `VM_SSH_PRIVATE_KEY_FILE`, `ADB_ACL_EXTRA_IPS`,
`VCN_CIDR`, `ORACLE_SODA_URL`, `VM_ADMIN_USERS`, `BOOTSTRAP_ADMIN_EMAILS`, `GOOGLE_CLIENT_IDS`.

## 6. New collections, jobs, endpoints

- Collections: `business_agg`, `business_riders`, `business_obs`, `ops_status`. All small. `business_riders` is
  deleted with the account.
- Leased jobs: `business-nightly` (daily, first run 35 min after start), `business-weekly-summary` (hourly check),
  `cas-rev-seed` (daily, first run 3 min after start).
- Endpoints: `/api/admin/business/*` (13 routes, MASTER_ADMIN; table in the API reference §1.12b). Campaigns accept
  `bestTime: true`. Metric `coroute_node_info{node,role,version}`.
- Route split: `/api/admin/business/*` is WEB. New LIVE rows: operator console, crew ride invites, public-ride
  safety review, rider page and ride lock, intelligence overview.

## 7. Privacy wording (for the lead; `gateway/public/privacy.html` was not edited)

Suggested addition to the privacy page, section on how we use data:

> **Understanding how CoRoute is used.** Once a day we count things like how many riders signed up, rode and
> bought a plan, and which riders have not ridden for a while. We use ride dates, plan dates and the hour you
> usually open the app. We do not use your position, speed or messages for this. If you agreed to offer e-mails,
> we may send them at the hour you usually open the app; you can unsubscribe at any time. We also look for signs of
> misuse, such as many accounts on one phone or repeated failed payments. A person reviews these; nothing is
> blocked automatically. These counts are deleted with your account.

Consent register (`docs/handbook/compliance/consent_and_retention_register.md`), suggested rows: `business_riders`
(hour-of-week histogram of app opens and e-mail clicks; legitimate interest for service analytics, consent for the
e-mail timing; kept until account deletion), `business_obs` (deleted nightly), `business_agg` (counts; at-risk and
signal lists hold user ids, replaced nightly).

## 8. QA checklist

**Clean-ups**

- C1 `cd gateway && node deploy/gen_caddy_routes.js --check` prints "covers every served route".
- C2 Add a dummy route in a scratch copy: the check and `release.sh --dry-run` fail.
- C3 `python3 gateway/deploy/update_adb_acl.py` without an inventory: exits 2 with "OCI_ADB_OCID is not set".
- C4 `setup_node.sh` on staging: `/etc/caddy/Caddyfile` has the peer IP, no `VM2_PRIVATE_IP` text.
- C5 `git check-ignore gateway/deploy/.env.example` prints nothing; `inventory.local.env` is still ignored.
- C6 After deploy, wait 5 minutes: a lease document has `casRev`. Stop vm1's gateway for 3 minutes and start it:
  `convoy-auto-end` moves back to vm1 (`/api/health` leases).
- C7 Two browser tabs redeem a coupon with one use left at the same moment: one succeeds.
- C8 `LIVE_RIDER_CAP` unset: no rider is refused.

**Business pages** (MASTER_ADMIN, light and dark, desktop and tablet)

- B1 Business > Overview: "Refresh numbers now" works; funnel steps never grow from one step to the next.
- B2 Retention: rows for the last 12 weeks; week 0 column filled; cells show the count on hover.
- B3 Conversion: plan numbers match Payments for one plan; a coupon's uses match Coupons.
- B4 At risk: each rider has reasons; a rider without offer consent shows why and the E-mail button is off.
- B5 At risk > Send win-back e-mail: the wizard opens at step 2 with the usernames and the Win-back starter;
  after sending, only consenting riders are in the campaign report.
- B6 E-mail wizard step 3: "At each rider's best time" queues; History shows it SCHEDULED, then SENT within 24 h;
  nothing goes out in the quiet hours.
- B7 Best send time: the grid fills after a few days of app use.
- B8 Review list: Mark reviewed / Open again; Audit log has `business.signal_review`; the rider's account is unchanged.
- B9 Servers: this node and the other node show numbers; stop vm2's gateway: its card turns red within 15 s.
- B10 Settings > Weekly summary: preview shows this week's numbers; "Send me a test now" arrives; switch off: no
  e-mail on Monday.
- B11 Settings > Templates > Weekly owner summary e-mail: edit the subject; the preview uses it.
- B12 A plain rider's token gets 403 on `/api/admin/business/overview`.
- B13 Delete a test account: its `business_riders` document is gone.

## 9. Owner decisions

1. **Weekly summary default.** It is on by default and goes to the administrators only. Turn it off in Settings
   if not wanted.
2. **Servers page, other node.** Choose `METRICS_ALLOW` with the peer's private IP (no secret) or one
   `METRICS_TOKEN` in the Vault for both.
3. **`LIVE_RIDER_CAP`.** Still unset. Suggested 2500 on the micros after a load test.
4. **Git history.** Rotate the items in `docs/security/GIT_HISTORY_CLEANUP.md`; rewriting history is optional.
5. **Play listing contact e-mail.** `store/LISTING.md` still has the personal address (public on Play). Use a role
   address?
6. **Privacy page wording** (section 7) and the consent register rows.
7. **E-mail code tries** (follow-up F1): do it in the next round?
8. **Thresholds** for the at-risk list (score 50) and the review signals: adjust after a month of real data.

## 10. Other agent's area (reported, not fixed)

- `gateway/test/qa316_behaviour.test.js` "weather privacy and validation" failed in one full run while the
  weather module was being changed (`Cannot read properties of null (reading 'at')`).
- New variables `WEATHER_PROVIDER`, `WEATHER_MET_URL` (their `src/weather_met.js`) were added to `.env.example`,
  because the new test requires every variable to be documented there. Later new variables need a line too.
- Their new avatar routes (`/api/me/avatar/original`, `/crop`) are covered by the WEB row `/api/me/avatar/*`.
  Any further new route needs a row in `deploy/route_split.md`.
