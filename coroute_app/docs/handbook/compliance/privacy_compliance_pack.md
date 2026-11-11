# Privacy compliance pack (DRAFT)

> **Draft for the owner and a qualified lawyer. This is not legal advice.** It describes what the
> code does on 11 Nov 2026 and maps it to India's Digital Personal Data Protection Act, 2023
> ("DPDP Act") and the DPDP Rules as we understand them. Items marked **[OWNER TO FILL]** or
> **[LEGAL REVIEW]** need a decision.

Public notice today: [`gateway/public/privacy.html`](../../../gateway/public/privacy.html)
(`https://coroute.devmonks.space/privacy`) and the plain-language page
[`privacy-and-security.html`](../../../gateway/public/privacy-and-security.html). Controller ("Data
Fiduciary"): CoRoute, operated by devmonks.space **[OWNER TO FILL: legal entity name, address]**.

## 1. Data inventory

Legal basis column: under the DPDP Act the grounds are **consent** (s.6) or a **legitimate use**
(s.7, e.g. a purpose the person voluntarily provided the data for, medical emergency threatening
life or health, legal obligations). Proposed bases are for legal review.

| # | Data element | Purpose | Proposed basis | Who can see it | Retention | Deletion path |
|---|---|---|---|---|---|---|
| 1 | Account: name/callsign, e-mail, hashed password (scrypt) or Google e-mail + name | Sign-in, identify rider to their group | Consent at sign-up (notice) / s.7(a) voluntary | Rider; group members see name; admins | Until account deletion | In-app Delete account (`DELETE /api/me`, immediate); web: `/delete-account` request |
| 2 | Username, profile picture (optional), full name | Social features, leaderboards | Consent (username automatic; picture optional) | Friends, crew members, other riders on profile; username on public leaderboards unless opted out | Until changed / deleted | Change in My profile; deleted with account |
| 3 | Phone number | Group riders can reach each other; emergency SMS roster | Consent / voluntary | Members of the current ride; never riders of other groups; operator only during an SOS (with `rosterEmergency`) | Until deleted | Profile edit; account deletion |
| 4 | Vehicle type, number, bike details (model, cc, colour, tank, mileage, cooling) | Show bike on map, fuel / engine care | Voluntary | Ride members (type/colour/model); bike summary owner + admin | Until deleted | Garage / profile; account deletion |
| 5 | Emergency contact name + phone (required before group rides) | Reach family in an SOS | Voluntary + s.7 medical emergency | Group members; accepted outside helper while alert open; server SMS; admin once per open alert (audited, not stored) | Until deleted | Profile; account deletion |
| 6 | Medical info (blood group, allergies ≤120, notes ≤200), optional | Responders tell a doctor | Voluntary + s.7 medical emergency (**no consent switch**, owner decision) | Lock screen; group, guardians and accepted helper **only while an SOS/crash alert is open**; never admins, timeline or notifications | Until cleared; copy on alert removed on resolve / trip end / retention | Clear fields; account deletion |
| 7 | Live location, speed, heading, battery, stop status | Group map, SOS, safety checks | Consent (permission + notice) | Current ride members only; nearby helpers get only the emergency point; guardians per tier | Latest position while ride active; removed 90 days after ride end | Leave ride; account deletion |
| 8 | Background location | Keep group map and SOS working with screen off | Consent (Android background permission + prominent disclosure) | as 7 | as 7 | Revoke permission; leave ride |
| 9 | Recorded routes (track chunks) | Replay, trip stats | Voluntary (ride) | Rider and ride members for the time they were in the ride | Simplified after 14 days; deleted after **90 days** | Delete trip; account deletion |
| 10 | Ride timeline (events with place names) | Shared trip report | Voluntary | Ride members | Kept with trip history; coordinates removed after 90 days | Account deletion ("Former rider" in others' history) |
| 11 | Chat and quick-status messages | Group communication | Voluntary | Ride members | With trip history | Account deletion |
| 12 | Voice (intercom audio) | Live group talk | Consent (mic permission) | Ride members live | **Never stored**; metadata (who, to whom, duration) 7 days | automatic |
| 13 | Microphone audio for siren detection | Warn about emergency vehicles | Consent (setting on by default, rider can switch off; mic permission) | Nobody (on-phone only) | Not stored | Siren alerts switch off |
| 14 | Motion sensor data | Crash / rider-down detection | Legitimate use (safety) / consent via notice | Nobody (on-phone only) | Not stored | n/a (crash detection is always on) |
| 15 | SOS / crash alerts (who, when, type, position) | Emergency response | s.7 medical emergency | Group, guardians, helpers, contacts, admins (no medical) | Position removed after 90 days; who/when/type kept with trip history | Account deletion |
| 16 | Live emergency link views | Family / responders see position | s.7 | Anyone with the link (first name, position, times) | Link 30 min; only a hash stored; view audit rows 180 days | Revoke in app |
| 17 | Ride Guardian grants (hashed tokens, PIN hash, tier, label) | Family monitoring | Consent (rider creates grant; group consent) | Guardian viewer per tier | Until expiry / revoke | Revoke / account deletion |
| 18 | Nearby rider settings `assistHelp`, `assistAsk` and network consent time | Safety network | Owner decision: always on (notice, no switch) **[LEGAL REVIEW: consent vs legitimate use]** | Server | Until account deletion | Account deletion |
| 19 | Safety audit log (ids and codes, no positions) | Prove the network works, stop misuse | Legitimate use | Admins | 180 days | Deleted with account |
| 20 | False-alarm count | Limit requests from abusers | Legitimate use | Admins | Last 10 | Admin reset; account deletion |
| 21 | Rider score inputs (5 per-ride counts, no route/position) | Private safety score, leaderboards | Owner decision: always on (notice) **[LEGAL REVIEW]** | Rider (score private); board totals public by username unless opted out | Until account deletion | Opt out of leaderboards; account deletion |
| 22 | Friends, blocks, crews, polls, votes, invites | Social | Voluntary | Participants | Until removed / account deletion | In app; account deletion |
| 23 | Trip reviews, place reviews, photos | Feedback, website stories | Consent (explicit tick to publish photos/story) | Admins; website only after approval as "Rider #" | Until withdrawn / account deletion | Withdraw in trip report; account deletion |
| 24 | Road hazard reports, hard-brake cells | Warn later riders | Legitimate use; **no rider ids stored** | Riders on the same road | Own expiry (30-365 days; 180 days for risk cells) | n/a (not personal once stored) |
| 25 | Push token, app version, push kind prefs | Notifications | Consent (Android notification permission; per-kind opt-outs) | Server, Google FCM | 5 newest per rider; removed on sign-out / account deletion / unregistered | Settings > Push notifications; account deletion |
| 26 | Diagnostics log (redacted, rounded positions only during rides) | Fix problems | Consent (sent only on the rider's action) | Support admins (views audited) | On phone 7 days / 20 MB; on server **30 days** | Clear on phone; deleted with account |
| 27 | Feedback messages, reply-by-email flag | Support | Voluntary | Admins | **[OWNER TO FILL]** (no automatic purge found) | Account deletion |
| 28 | Payments: orders, amounts, Razorpay ids, receipts, coupon use | Sell plans on the website | Contract / legal obligation (tax records) | Rider (own), admins | **[OWNER TO FILL: statutory period, e.g. 8 years for tax]**; memberships removed with account | Account deletion removes memberships; ledger retention **[LEGAL REVIEW]** |
| 29 | Marketing consent (offers e-mail) with history | Offer e-mails | **Consent, opt-in, default off** | Server | Until withdrawn; erased with account | Account page toggle; unsubscribe link |
| 30 | E-mail suppression list (SHA-256 of address) | Never mail an unsubscribed address | Legitimate use | Admins (masked) | Kept even after account erase | Admin removal on request |
| 31 | Partner perks push opt-in | Curated perks | Consent, default off | Server | Until changed | Settings |
| 32 | Operator applications: business e-mail, phone, org details | Approve operators | Contract / voluntary | Applicant, master admins | **[OWNER TO FILL]** | Request to admin |
| 33 | Operator attendance (who joined/left/finished, distance, incidents without location) | Club operations | Voluntary participation in an operator ride **[LEGAL REVIEW: operator as joint controller / processor]** | Operator owner and co-organisers | **[OWNER TO FILL]** | Leave club; account deletion |
| 34 | Server SOS SMS rows (numbers, names, links) | Deduplicate and track delivery | s.7 | Admins | Personal fields purged **48 h** after last status change | automatic |
| 35 | Technical logs (IP, request time, request id) | Security, operations | Legitimate use | Operators of the service | journald rotation (privacy.html says "within a few weeks") | automatic |
| 36 | Website page counts (no cookies) | Site analytics | Not personal (aggregated per day/path) | Admins | — | — |
| 37 | Local on-phone data: offline map tiles, SMS roster (encrypted), fuel profile, coupon code from QR, 3.57 emergency text queue (contact numbers + text until sent) and ledger (number hashes) | Offline use, SOS fallback, phone-first emergency texts | On-device | The phone only | Maps 7 days after trip (30 if never ended, 300 MB cap); roster deleted at ride end; coupon 7 days; text queue 48 h after each text finished | Uninstall / sign out |

## 2. DPDP Act 2023 considerations

### 2.1 Notice and consent (s.5, s.6)

- **Notice** must list the personal data, purposes, how to withdraw consent, how to exercise rights,
  and how to complain to the Data Protection Board, in clear language, available in English and
  (on request) in the Eighth Schedule languages. The app ships English, Hindi and Telugu UI.
  **Done (11 Nov):** rights, grievance officer section and Board complaint text are in `privacy.html`.
  Hindi/Telugu versions remain **[OWNER TO FILL]**.
- **Consent records**: marketing consent already keeps time and source (last 20 changes). The
  nearby-rider network keeps the consent time. **Action:** record the version of the privacy notice
  accepted at sign-up and at material changes **[OPEN]**.
- **Withdrawal** must be as easy as giving consent. Comfort and marketing items have switches.
  Always-on safety processing (crash detection, help/ask nearby riders, score report) relies on
  notice; **[LEGAL REVIEW]** whether these are better grounded as legitimate use (medical
  emergency / voluntary provision) and how to state that in the notice.
- A **Consent Manager** (registered under the Act) is optional; not planned.

### 2.2 Data principal rights (s.11-s.14)

| Right | How CoRoute meets it today | Gap |
|---|---|---|
| Access / summary of data and processing | Profile, trip history, My profile stats in the app; "request a copy" by e-mail (privacy.html) | No self-service export. **Action:** add a data export (JSON) or a documented 30-day manual process |
| Correction, completion, updating | Profile and garage edits | — |
| Erasure | In-app Delete account (immediate cascade); web deletion request page | Aligned (11 Nov): at once in the app, 48 h by request, backups 30 days |
| Grievance redressal | Contact e-mail on privacy.html | **Grievance officer name, e-mail and response time [OWNER TO FILL]**; must respond within the period the Rules set |
| Nominate | Not supported | **Action:** describe a nominee process (e-mail with proof) **[LEGAL REVIEW]** |

### 2.3 Grievance officer

| Field | Value |
|---|---|
| Name | **[OWNER TO FILL]** |
| E-mail | **[OWNER TO FILL]** (use a role address, not a personal one) |
| Postal address | **[OWNER TO FILL]** |
| Response time commitment | **[OWNER TO FILL]** (proposal: acknowledge in 48 h, resolve in 15 days; check against the Rules) |

### 2.4 Security safeguards and breach notification (s.8(5), s.8(6))

Safeguards: [../technical/security_overview.md](../technical/security_overview.md). Breach process (draft):

1. **Detect and contain** (on-call, SEV-1): rotate affected secrets, preserve logs, stop the leak.
2. **Assess** within 24 h: what data, how many riders, likely harm (location and medical info are
   highest risk).
3. **Notify the Data Protection Board of India** of the breach and **each affected data principal**
   without delay, in the form and time the DPDP Rules require (the Rules describe an initial
   intimation without delay and a detailed report within 72 hours) **[LEGAL REVIEW: confirm current
   Rules]**. Content: nature, extent, timing, likely consequences, mitigation, what riders can do,
   contact.
4. **Notify CERT-In** within 6 hours of noticing a reportable cyber incident (CERT-In directions,
   April 2022) **[LEGAL REVIEW]**.
5. Post-mortem (template in the incident response guide); update safeguards.

### 2.5 Children (s.9)

CoRoute targets **licensed riders aged 18+** (privacy.html "Children"; Play target audience 18+).
Verifiable parental consent is not implemented, so the service must not knowingly process
children's data. **Action:** add an 18+ confirmation at sign-up **[OPEN]** and a process to delete
an account reported as a minor's.

### 2.6 Purpose limitation and retention (s.8(7))

Retention rules: [consent_and_retention_register.md](consent_and_retention_register.md). Erase when
the purpose is served or consent is withdrawn; the DPDP Rules also set inactivity-based erasure for
some large platforms **[LEGAL REVIEW: applicability; CoRoute is not a Significant Data Fiduciary
today]**. Gaps: no automatic purge of feedback messages, operator applications, inactive accounts.

### 2.7 Processors and cross-border transfers (s.8(2), s.16)

The Act allows transfers except to countries the Government restricts by notification. Processors
must be under a contract.

| Processor | Data | Location | Contract / note |
|---|---|---|---|
| Oracle Cloud Infrastructure (DB, VMs, Object Storage, Vault) | all stored data | India (Hyderabad region) | OCI terms + DPA **[OWNER TO CONFIRM]** |
| Google Firebase Cloud Messaging | push token, usernames, short text | Global (Google) | Firebase terms / DPA |
| Google Sign-In | e-mail, name (from Google) | Global | Google terms |
| Google Play (In-App Review, Install, vitals) | Play-side data | Global | Play terms |
| SMTP provider **[OWNER TO FILL]** | e-mail address, receipt / offer content | **[OWNER TO FILL]** | DPA needed |
| MSG91 (India) / Twilio (US) | contact phone numbers, rider first name, live link | India / US | DPA needed; DLT registration in India |
| Razorpay | order amount, e-mail/phone prefill, payment data (Razorpay is itself regulated) | India | Razorpay terms |
| OpenStreetMap services (Photon, Nominatim, OSRM, Overpass), Open-Meteo | search text, rounded coordinates, no rider id | EU / global | Public services; usage policies |
| OpenStreetMap tile servers | viewer's IP when loading tiles (phone, live page) | Global | OSM tile policy |

**Done (11 Nov 2026):** listed in privacy.html "Service providers". Processor agreements remain
**[OWNER TO CONFIRM]**.

## 3. Findings: privacy.html out of date with the code (11 Nov 2026)

| # | privacy.html says | Code / owner decision now | Fix |
|---|---|---|---|
| 1 | Summary: "you can switch crash detection off"; "Your choices": switch off crash detection, emergency texts, help from nearby riders, spoken alerts, lock screen view | Crash detection, emergency texts, lock-screen ride, help/ask nearby riders are **fixed on** (SETTINGS_MINIMAL); voice alerts still a switch (emergencies always spoken) | Rewrite summary bullets and "Your choices and rights" |
| 2 | Summary: "A few riders of other groups ... you can turn this off" | Always on (owner decision, 11 Nov; #nearby-help section already updated) | Fix the summary bullet |
| 3 | "Emergency texts and Groups nearby are off until they are switched on"; #emergency-texts "This is off until you switch it on" | Emergency texts **fixed on**; "Receive emergency texts from my ride group" opt-out (`smsOptOut`) still exists | Update both places |
| 4 | Diagnostics: send "from Settings, More, Diagnostics" | Now Profile > Help > Send feedback (Attach diagnostics log / View diagnostics) | Update path |
| 5 | Spoken alerts: lock screen shows own ride only if "Show ride on lock screen" is on | Fixed on | Update |
| 6 | "CoRoute is supported by transparent membership plans" | Access mode may be Free for everyone | Neutral wording |
| 7 | Contact: personal e-mail | Use a role address and name the grievance officer | Update |
| 8 | Deletion "within 30 days" by e-mail vs delete-account page "24 to 48 hours" | — | Align |
| 9 | Processors list incomplete (FCM, SMTP, SMS, Razorpay) | see §2.7 | Add |
| 10 | No DPDP rights / Board complaint text | — | Add §2.1 notice items |

**Status (11 Nov 2026): all ten fixed** in `gateway/public/privacy.html` (also `terms.html`,
`delete-account.html`, `privacy-and-security.html`). Summary of what changed:

1-5. Crash detection, emergency texts (phone and server SMS via MSG91/Twilio), the lock-screen ride view,
     Medical ID during an alert and help/ask nearby riders are described as always on; voice alerts stay a
     rider choice. Crash detection starts from about 12 km/h.
4.   Diagnostics: sent only when the rider chooses (Profile > Help > Send feedback, "Attach diagnostics log" or
     View diagnostics), answers the after-ride prompt, or taps Send on a support request.
6.   Neutral wording: plans are bought on the website; hosting may be free for everyone (access modes).
7.   Contact: no personal address. Pages render `SUPPORT_EMAIL` at startup (`src/pages.js`
     `<!--support-email-->` blocks); empty = the home page contact form. New "Grievance Officer" section;
     name, address and response times remain **[OWNER TO FILL]** in an HTML comment.
8.   One deletion timeline on every page: in the app at once (Profile > Account > Delete account); a request
     through `/delete-account` within 48 hours; encrypted backups expire within 30 days
     (`BACKUP_RETENTION_DAYS`); payment ledger records are kept for accounting (`repo.deleteUserCascade`).
9.   New "Service providers" table (Oracle Cloud Hyderabad, FCM, Google Sign-In, SMTP provider, MSG91/Twilio,
     Razorpay, Nominatim/Photon/OSRM/Overpass, OSM tiles, Open-Meteo). The SMTP provider's name is
     **[OWNER TO FILL]**.
10.  Rights (summary, correction, erasure, nominee), withdrawal, Grievance Officer and Data Protection Board
     complaint text added. Hindi/Telugu versions are still open (§2.1).

Also added: offer e-mails opt-in and unsubscribe, push kinds opt-out, clubs/operators see an emergency contact
only during that member's open SOS, 18+ only, and the new `/refunds` policy. Tests:
`gateway/test/website_legal_356.test.js`. **Legal review is still pending.**

## 4. Privacy-by-design measures already in the product

Room isolation, minimum disclosure across groups, medical info only during open alerts, rounded
public numbers, usernames-only leaderboards with opt-out, data-only pushes without personal data,
on-phone crash and siren processing, voice never stored, diagnostics redaction on phone and server,
EXIF stripping, encrypted backups, immediate account erase with "Former rider" anonymisation,
road reports without rider ids. Details: [../technical/security_overview.md §8](../technical/security_overview.md#8-privacy-by-design-security-relevant).
