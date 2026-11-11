# Incident response and SOS operations

Written 11 Nov 2026. This is an operating draft for a very small team (the owner plus helpers).
Fill in the names and phone numbers marked **[OWNER TO FILL]** before launch.

## 0. Non-negotiable rules

1. **Never block or delay 112.** CoRoute is an aid, not an emergency service. The app, live page
   (`/e/:token`) and every message we send tell people to call **112** (108 ambulance, 100 police).
   Support staff never ask a rider or bystander to wait for CoRoute instead of calling 112.
2. Safety paths stay on: SOS, crash detection, emergency texts and Medical ID are locked switches.
   During an incident never turn off `assistNetwork`, `guardianLink`, `soloCheckIn` or other safety
   switches unless they are the proven cause of harm, and record the reason (the console requires one).
3. Medical info is never shown to admins. Admins can see that an alert is open, who raised it,
   where, and who is going to help; they can fetch the rider's **emergency contact** once per call
   (audited, not stored).
4. Talk to riders and contacts with care and in plain words; no blame, no speculation.

## 1. Severity matrix

| Severity | Definition | Examples | Response target | Who |
|---|---|---|---|---|
| **SEV-1** | A safety path is broken or at risk for any rider, or a confirmed real emergency needs follow-up | SOS not delivered; crash alarm not opening; both gateways down during rides; SMS provider silently failing during an open SOS; data breach | Acknowledge 15 min, mitigate 1 h, 24x7 | On-call + owner |
| **SEV-2** | Major non-safety outage or a safety feature degraded with a fallback working | Website/payments down; push down; DB outage (live rides continue); one VM down; false-SOS wave | Acknowledge 1 h, mitigate 4 h | On-call |
| **SEV-3** | Partial degradation | Map search failing; one admin screen broken; Razorpay webhook retries; mail delivery delays | Next business day | Owner/dev |
| **SEV-4** | Cosmetic / question | Wording, single-user issue with a workaround | Backlog | Owner/dev |

A **false SOS** reported by a rider is SEV-3 unless it repeats across riders (then SEV-2: check the
crash rule thresholds and the false-SOS review in `docs/features_355/sensor_safety.md`).

## 2. On-call

| Role | Person | Contact |
|---|---|---|
| Primary on-call (week rotation) | **[OWNER TO FILL]** | **[OWNER TO FILL]** |
| Secondary / escalation | **[OWNER TO FILL]** (owner) | **[OWNER TO FILL]** |
| Privacy / grievance officer (DPDP) | **[OWNER TO FILL]** | see [../compliance/privacy_compliance_pack.md](../compliance/privacy_compliance_pack.md) |

Tools on-call needs: Bastion SSH access to both VMs, `/admin` MASTER_ADMIN account, OCI console
(NLB, ADB, Vault, Object Storage), Razorpay dashboard, SMS provider dashboard, Firebase console,
Play Console, the DuckDNS / devmonks.space DNS account.

## 3. SOS and crash incident handling

### 3.1 What admins see

| Place | What |
|---|---|
| `/admin` > Emergencies (`GET /api/admin/emergencies`) | Open alerts: rider name, group, type (SOS, crash, rider-down, member report), time, position, responders, status |
| Emergency contact button (`POST /api/admin/emergencies/:groupId/:alertId/contact`) | Emergency contact name + phone and rider name, only while the alert is open; 10/min; audited `ADMIN_CONTACT` (number not stored) |
| `/admin` > Safety (`GET /api/admin/safety`) | Safety network incidents, false-alarm counts, latest audit rows |
| `/admin` > SMS log (`/api/admin/sms/log`) | Server SOS SMS rows and delivery status (numbers purged after 48 h) |
| Public ride reports (`/api/admin/public-ride/*`) | Reports, contact log, suspensions |
| Operator console | Operators see an SOS banner for their rides and (with `rosterEmergency`) the contact during the SOS, audited |

Admins **cannot** see medical info, listen to the intercom, or read anything outside what is above.

### 3.2 Playbook: open SOS or crash alert

1. **Do not interfere with the group.** The rider's group, accepted nearby helpers, guardians and
   emergency contacts are already alerted by the system. Watch the alert in `/admin` > Emergencies.
2. If the alert stays open with **no responder after 5 minutes** and the rider's position is fresh:
   - press the emergency contact button and call the contact: say who you are, that the rider's
     CoRoute SOS is open, the last position (place name), and ask them to call **112** if they
     cannot reach the rider. Never promise rescue.
   - if no contact is on file, or the contact cannot be reached, and the situation looks serious
     (crash alert, no movement), call **112** yourself with the last known position and say it
     comes from a rider safety app alert.
3. If the position is stale (no fix for several minutes): check `/admin` for "lost signal after
   riding fast" (`NO_SIGNAL` escalation) and whether the SOS was relayed by another phone; follow
   step 2 with the last known place.
4. When the alert is resolved or cancelled, the group and contacts get "safe now". Nothing to do
   unless the rider asks for help afterwards.
5. Log the incident (time, alert id, actions, outcome) in the incident log **[OWNER TO CHOOSE
   location]**. Never copy medical info or phone numbers into the log.
6. If the alert turned out false: thank the rider, ask whether they can send diagnostics (Profile >
   Help > Send feedback > Attach diagnostics log). Reset false-alarm counts only when justified
   (`POST /api/admin/users/:userId/false-alarms/reset`).

### 3.3 Playbook: SOS reported as not delivered (SEV-1)

1. Check `/api/health` and `/api/health/live` on both hosts, mirror connected, `journalctl -u
   coroute-gateway` for `[http] ... 5xx` and socket errors around the time.
2. Ask the rider (or tester) for the diagnostics log: `sos.raise`, `sos.send`, `sos.ack`,
   `sos.sms_fallback`, `realtime.closed` events show where it stopped. Match `X-Request-Id`.
3. Check the SMS log and provider dashboard; check FCM if a push was involved.
4. If a code defect is suspected: freeze releases, reproduce with the gateway test suite
   (`sos2`, `safety_review_355`, `two_node_failover`), fix forward, deploy VM2 then VM1.
5. Communicate to affected riders (template 6.3).

## 4. Outage runbooks

| Situation | Symptoms | Immediate actions | Rider impact | Comms |
|---|---|---|---|---|
| **VM1 gateway down** | NLB fails over to VM2; brief reconnects | `systemctl status coroute-gateway`; journal; restart; if VM1 cannot recover, keep VM2 serving (it has every room). | Seconds of reconnect; rides intact | None unless > 10 min |
| **Both gateways down** (SEV-1) | `/api/health` unreachable on both hosts | Restart VM2 then VM1; check secrets service, memory (`MemoryMax=700M`), disk, Caddy; rollback if a deploy caused it | Live map and intercom stop; **phones fall back to SMS composer for SOS**; crash detection keeps working on the phone; Medical ID still on lock screen | Status post + push/website notice when back |
| **Database down** (SEV-2) | `/api/health` 503 `db: DOWN`; `/api/health/live` 200 | Check ADB state and ACL in OCI; do not restart gateways repeatedly; wait for ADB; writes resume within 30 s | Live rides, chat, positions, voice, SOS relay continue in memory; sign-in, joining new rides, payments fail; no jobs run | Website notice if > 30 min |
| **FCM down / misconfigured** | `push` errors in journal; no pushes | Check `FCM_SERVICE_ACCOUNT_JSON`, Google status; nothing else to do | Social / invite / campaign pushes delayed; **safety does not depend on push** (live sockets, SMS) | None (SEV-3) |
| **SMS provider down** | SMS log rows failing; provider dashboard | If during an open SOS: call the contact from `/admin` (3.2); switch provider (`SMS_PROVIDER`) if the other is configured; or `off` to fall back to the older chain | Phones still text from the rider's SIM when offline; server texts delayed | Internal |
| **Razorpay webhook failures** | Razorpay dashboard shows failed deliveries; orders stuck PAID-not-active | Check `RAZORPAY_WEBHOOK_URL` matches the dashboard URL (other URL answers 410 by design); check webhook secret; `/api/membership/verify` from the browser normally settles anyway; run `/admin` > Plans > Reconcile; activate manually only via admin "Change plan" (audited) | Buyer may wait for activation | E-mail the buyer (template 6.4) |
| **Mail (SMTP) failures** | `mail-retry` job errors | Check SMTP credentials and provider; mails are retried every 5 min | Receipts / offer mails delayed | None |
| **TLS / certificate failure** | Browser errors; Caddy logs ACME errors | Check `DUCKDNS_TOKEN`, DNS CNAME, Caddy build with duckdns module | App cannot connect on that host (falls back to the other host) | Status post |
| **Domain unreachable** | `coroute.devmonks.space` DNS broken | App falls back to `coroute.duckdns.org` automatically; fix DNS | Minimal | None |
| **Abuse / harassment report** | Report in `/admin` (chat report, public ride report) | Hide content, warn (`Warn` text ≤ 280 chars), suspend, or block account (`PATCH /api/admin/users/:userId/status`) | — | Reply to reporter |
| **Data breach suspected** (SEV-1) | Unexpected access, leaked secret | Rotate the affected secrets (deployment guide §9), preserve logs, assess scope, follow DPDP breach process in the privacy pack | — | Legal/regulator per pack |

## 5. Communication channels

- Riders: admin push campaign (kind **Update**, Play policy guard applies, no links), website
  `/updates` board post, in-app admin warning (one rider), e-mail only to riders who opted in
  (offers) or transactional (receipts).
- Operators: e-mail to the operator owner; operator console broadcasts are theirs to send.
- Public: website notice. **[OWNER TO FILL]** social account if any.

## 6. Templates

### 6.1 Outage notice (push, ≤ 120 characters, no links)

> CoRoute had a service problem from 14:05 to 14:40. It is fixed. SOS by text kept working. Sorry for the trouble.

### 6.2 Degraded service in progress (website `/updates`)

> We are fixing a problem with [live map / group talk / sign-in] since [time]. Crash detection and
> the lock-screen Medical ID work on your phone without the server. If you need help, call 112.
> We will post here when it is fixed.

### 6.3 SOS delivery problem (direct to affected riders, e-mail or call)

> On [date] between [time] and [time] some CoRoute SOS alerts reached the group late or only by
> text message. We are sorry. The cause was [plain cause] and it is fixed in [build/server update].
> If you were affected, please reply; we would like to understand what happened to you.

### 6.4 Payment not activated

> We received your payment for [plan] on [date]. Your plan was not switched on at once because of a
> problem on our side. It is active now until [date]. No action is needed. Order [order id].

### 6.5 Holding reply to a rider report

> Thank you for telling us. We are looking into it and will reply within [1 day]. If you can,
> open Profile > Help > Send feedback and tick "Attach diagnostics log" so we can see the timing on
> your phone. The log has no messages, names or exact places.

## 7. Post-mortem template

```
# Post-mortem: <title>                                  Severity: SEV-x
Date / duration: <start> to <end> IST (<minutes>)
Author: <name>        Reviewers: <names>        Status: draft / final

## Summary
Two or three sentences: what happened, who was affected, how it ended.

## Impact
- Riders affected (number, rides, SOS alerts involved and their outcome)
- Safety impact: was any SOS or crash alert delayed or lost? (yes/no, details without personal data)
- Money impact (orders, refunds)

## Timeline (IST)
- hh:mm  detection (how: rider report / monitor / admin)
- hh:mm  ...
- hh:mm  resolved

## Root cause
Technical cause and why safeguards did not prevent it.

## What went well / what went badly

## Action items
| # | Action | Owner | Due | Tracking |
|---|---|---|---|---|

## Lessons for the safety invariants
Does docs/testing/safety_invariants.md need a new invariant or test?
```

Blameless: describe systems and decisions, not people.
