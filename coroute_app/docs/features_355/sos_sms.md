# SOS SMS: phone-first (3.57), server provider optional

**Owner decision (3.57)**: there is no SMS provider. Emergency texts are sent **by the rider's own
phone, from their SIM**, automatically, without a tap. The server path (MSG91 / Twilio, section 2)
stays in the code but is **off** (`SMS_PROVIDER=off`); it is not the plan.

An SOS reaches the rider's emergency contacts by text in these ways:

1. **Phone-first automatic texts** (3.57): every SOS of the rider (SOS hold, crash alarm ran out,
   rider-down, missing-rider and solo check-in escalations that raise an SOS) texts the emergency
   contacts from the phone, with retries, delivery status and an "I'm safe now" follow-up.
2. **Group fallback round** (3.56): when the SOS cannot reach the group over the internet for 45 s,
   the lead, sweeper and nearest riders get a text too (numbers already texted are skipped).
3. **Server provider** (optional, off): section 2.

Ride Guardian watchers get the SOS and the arrival through browser push, as before
(`guardian_push.js`, checked every 15 s; the emergency push is sent with high urgency).

## 1. From the rider's phone (app)

### 1.1 Permission and disclosure

- `AndroidManifest.xml` declares `SEND_SMS` and
  `<uses-feature android:name="android.hardware.telephony" android:required="false"/>` (tablets without
  a SIM stay eligible on Play). No `READ_SMS`, `RECEIVE_SMS` or `READ_PHONE_STATE`.
- Play: the "Physical safety / emergency alerts" exception, with the Permissions Declaration Form and
  video 2 (`docs/handbook/compliance/play_store_compliance.md` 3a, 3b).
- Prominent disclosure (`lib/presentation/safety/emergency_texts_disclosure.dart`), one calm screen
  before the system prompt: "CoRoute sends a text from your phone to your emergency contacts when you
  raise an SOS or after a crash alarm, even if you can't touch the phone. Normal SMS charges from
  your carrier apply." Shown:
  - once after the rider saves an emergency contact (profile form);
  - from the permissions screen ("Emergency texts", optional);
  - from Safety health ("Emergency texts" item, **Allow** fix button).
- **Denied**: nothing is sent automatically; the SOS screen says so and the 3.56 composer flow stays
  (the messages app opens prefilled, the rider or a bystander presses Send). Safety health shows
  "Not allowed" with the fix.

### 1.2 Automatic texts

`SafetyService` (section "3.57 phone-first texts") + `lib/domain/safety/emergency_texts.dart`
(pure, tested) + `android/.../EmergencyTexts.kt` (native queue) + `SmsChannel.kt` (channel).

- **When**: a new pending SOS of this rider (`_watchPendingSos`, and the offline solo ride's
  SOS). All automatic escalations raise that same SOS, so one hook covers them.
  - A deliberate press (SOS hold, ride notification) waits **10 s** (`pressGrace`): cancelling the
    SOS within it texts nobody. Automatic SOS (crash countdown ran out, Need Help, rider-down,
    check-in escalations) go at once: the countdown was the cancel window.
  - The hidden developer impact (a test alarm) never texts. An SOS older than 2 h restored from disk
    is not texted.
- **Who**: the emergency contacts (the profile holds one today; the queue takes up to **5**), each
  number once, never the rider's own number.
- **Text** (`EmergencyTexts.alert` = `SmsText.sos` with the live link): name, "SOS ... needs help" or
  "may have crashed", time, live link `https://<origin>/e/<code>` (`PendingSos.linkToken`),
  coordinates as text, plus the map link and ride name only while the text still fits one part.
  Longer texts (long or non-GSM names) go multipart. Example:
  `CoRoute SOS: Kiran needs help at 14:05. Live: https://coroute.devmonks.space/e/Ab3dEf6hIj9lMn0pQr2tUv Lat 12.97160 Lng 77.59456`
- **Dedupe per incident**: the incident is the SOS `clientId`. `EmergencyTextLedger` (kept with the
  pending SOS, `EmergencyTextStore`, number hashes only) records each texted incident, so a resent,
  relayed, crash-upgraded or restored SOS never texts twice. Job ids are
  `<clientId>|A|<fnv32(number key)>`; the native queue also ignores a known id.
- **Daily cap**: 30 texts per rolling 24 h (alert and test texts). "Safe now" only follows texts
  already sent.
- **Sending** (native, `EmergencyTexts.kt`):
  - Jobs are committed to a private SharedPreferences file before sending, so an app kill or reboot
    does not lose them (`BOOT_COMPLETED` / `MY_PACKAGE_REPLACED` resume the queue).
  - SIM: the default SMS SIM, else the default SIM, else the system default (no SIM listing, so no
    READ_PHONE_STATE). With dual SIM set to "ask every time" the system default is used.
  - One text per contact; multipart when needed. Sent and delivered `PendingIntent`s per part
    (explicit broadcasts to `EmergencyTextReceiver`, `FLAG_IMMUTABLE`, unique request codes), so
    reports arrive with the screen locked, the app in the background or the process restarted.
  - Delivery: a delivery report counts as delivered (immutable intents get no PDU to read).
  - **Retries**: `NO_SERVICE`, `RADIO_OFF` (airplane mode), `GENERIC_FAILURE`, and no sent report
    within 3 min, after **30 s, 2 min, 5 min, 10 min**, then FAILED. Woken by a Handler while the
    process lives, by an inexact `AlarmManager.setAndAllowWhileIdle` alarm otherwise (no exact-alarm
    permission), and 3 s after a network comes back (`ConnectivityManager`, ACCESS_NETWORK_STATE).
- **Status**: per job QUEUED / SENDING / SENT / DELIVERED / FAILED / CANCELLED back to Dart
  ("textStatus"), shown on the SOS screen and the solo card (`contactTextsLine`, for example
  "Texted your emergency contact from your phone. Delivered."), and written to the diagnostics log
  (`contact_text`: kind, state, try, code, `***210`; never full numbers or text).
- **Cancelled / resolved** (`ConvoyService.onMySosClosed`: the rider's cancel or "Help reached me",
  the lead's resolve, `ALERT_RESOLVED` for the rider's own alert; the solo ride's "I'm safe now"):
  waiting texts are cancelled, and every contact whose alert left the phone gets
  `CoRoute: <name> is safe now. The SOS was closed at HH:MM. No action is needed.` once (always on).
- **Safety health**: "Emergency texts" (ready / not allowed / no SIM / no telephony) with the fix,
  and **Send a test text to my emergency contact** (after a confirmation; "CoRoute test: emergency
  texts work. No action is needed.").
- **Solo check-in by ETA** (`solo_guardian_service.dart`) already sends its overdue / fine-now
  texts with the same permission.

### 1.3 Group fallback round (3.56, unchanged apart from dedupe)

`_smsRound`, `lib/domain/safety/sms_plan.dart`:

- When the SOS cannot reach the group over the internet for 45 s: the lead, sweeper and nearest
  riders (`SmsPlanner`, at most `smsMaxRecipients`, within the 30-min text budget). Numbers the
  automatic texts already cover for this SOS are skipped.
- With SEND_SMS denied: the messages app opens with every recipient (the rider or a bystander presses
  Send); in the background the round only shows `composerWaiting`, and **Text the group now** opens it
  once the phone is in hand (it asks to unlock first over the lock screen).
- The pending SOS itself is kept on disk and resent over the internet with the same `clientId`.

## 2. From the server (gateway) - optional, off (`SMS_PROVIDER=off`)

Kept for a future provider; not used while the owner has none. With `off`, nothing here sends.

`gateway/src/sos_sms.js` (`SosSms`), attached to `EmergencySmsGateway` as `sosSms` by
`src/notifications.js`.

### Flow

1. The SOS reaches the gateway.
   - `convoys.raiseSos` raises the RAISED event, and `safety_network.onEmergency` calls
     `emergencyGateway.dispatchForSos`. The socket handler calls it too, with the phone's
     message (this registers `smsLinkToken`).
   - It is skipped when the phone says it already texted (`clientSentSms`).
2. The contacts: the profile emergency contact plus any the app sent. They must be valid numbers,
   distinct, at most 5.
3. With a provider chosen and configured (`isActive`), the server makes a live link with a
   22-character code (fits a DLT variable) and texts each contact once.
   - The row key is `<alertId>:SOS:<sha256(number)>`, unique, so a relayed copy, a retried SOS
     or the other gateway node never texts twice.
   - With provider `off`, the earlier providers / outbox path of `emergency_sms_gateway.js` is
     used unchanged.
4. **Retries**: network errors, 429 and 5xx are retried after 30 s, 2 min and 10 min (the leased
   job `sos-sms`, every 15 s). A 4xx refusal fails at once.
5. **Delivery receipts**: the provider calls
   `POST /api/sms/receipts/<msg91|twilio>/<SMS_WEBHOOK_TOKEN>`.
   - The token is compared in constant time. Twilio callbacks are also checked with
     `X-Twilio-Signature` when `TWILIO_AUTH_TOKEN` is set.
   - Each contact's row becomes DELIVERED or FAILED.
6. **Resolved or cancelled** (not when the alert only expired):
   - "Safe now" goes to every contact whose SOS text was SENT or DELIVERED.
   - A text still waiting for a retry is cancelled. A "safe now" for an SOS they never got would
     only confuse.
   - It is sent once per contact, even when both nodes see the resolve.
7. **Cost guard**:
   - At most **5** contacts per SOS (`maxPerSos`).
   - At most **20** SOS texts per rider per India day (`maxPerUserDay`). "Safe now" texts are
     exempt: they only go to contacts already texted.
   - Capped contacts are reported (CAPPED), not texted.
8. **Privacy**:
   - Logs carry only the masked number (`***210`) and the SOS id. Provider errors are
     redacted.
   - Numbers, names, links and texts are deleted from the rows 48 h after the last status change.
     The admin log shows masked numbers only.
9. **Outbound hosts** (https only, no redirects): `control.msg91.com`, `api.msg91.com`,
   `api.twilio.com` (`SMS_HOSTS`).

### Providers (one interface)

| Provider | How |
| --- | --- |
| `msg91` | MSG91 Flow API `POST https://control.msg91.com/api/v5/flow` with header `authkey`. Body: `template_id` (the MSG91 template id of SOS or safe now), `sender` and `recipients: [{mobiles, name, token, lat, lng, time}]`. MSG91 holds the DLT-registered text and fills the variables. |
| `twilio` | `POST https://api.twilio.com/2010-04-01/Accounts/<SID>/Messages.json` with To, From (or MessagingServiceSid), Body (the full text) and StatusCallback. For Indian numbers the text must match the DLT template registered with Twilio exactly. |
| `log` | Records the text only (testing / staging). Nothing leaves the server. |
| `off` | The earlier path (`TELEPHONY_PRIMARY_PROVIDER` drivers and the outbox). |

## Web admin: Notifications > SMS

- **Settings**:
  - provider, sender id (DLT header, 6 letters), DLT entity id, DLT template ids (SOS, safe
    now), MSG91 template ids;
  - SMS per SOS (1 to 10), SMS per rider per day (1 to 100);
  - "Send safe now".
- **Secrets**: listed as **Set / Not set** only. They are environment variables on the server
  and are never stored or shown.
- **Delivery receipts URL** to paste at the provider (the token part is shown as a placeholder).
- **Send test SMS** to one number. It uses the safe-now template with the name "CoRoute test"
  and is not counted in the caps.
- **SMS log** per SOS: kind, masked number, status, tries, note.

Endpoints (MASTER_ADMIN):

- `GET` / `PUT /api/admin/sms/settings`
- `POST /api/admin/sms/test {phone}`
- `GET /api/admin/sms/log`

Public: `POST /api/sms/receipts/:provider/:token`.

## Templates (web admin > Templates)

`sos_sms` and `sos_safe_sms` keep their variables in their registered order (anything else is
refused). Each value is cut to 30 characters. Any change of the words shows a warning, because the
new text must be registered with DLT first.

Default texts (one SMS part with typical values):

```
CoRoute SOS: {{name}} needs help. Live: {{origin}}/e/{{token}} Lat {{lat}} Lng {{lng}} at {{time}} IST. Call 112. -CoRoute
CoRoute: {{name}} is safe now. The SOS alert was closed at {{time}} IST. No action is needed. -CoRoute
```

## Owner setup

Not needed for 3.57 (phone-first). Only if a server SMS provider is added later.

### A. DLT registration (India, required for both providers)

1. Register the business as a **Principal Entity** on an operator DLT portal: Jio TrueConnect,
   Vodafone Idea Vilpower, Airtel DLT or BSNL. You need the company PAN, GST and a letter of
   authorisation. Note the **Entity ID** (19 digits).
2. Register a **Header (sender id)** of 6 letters, for example `CORUTE`, category
   **Transactional / Service**.
3. Register a **Content Template** for each text, type **Service Implicit** (safety alerts that
   are part of the service; confirm the category with your provider), with these exact texts.
   - Replace `https://coroute.devmonks.space` with your `PUBLIC_ORIGIN` if it differs.
   - Each `{#var#}` holds at most 30 characters.

   SOS:
   ```
   CoRoute SOS: {#var#} needs help. Live: https://coroute.devmonks.space/e/{#var#} Lat {#var#} Lng {#var#} at {#var#} IST. Call 112. -CoRoute
   ```
   Safe now (also used by the admin test SMS):
   ```
   CoRoute: {#var#} is safe now. The SOS alert was closed at {#var#} IST. No action is needed. -CoRoute
   ```
4. **Whitelist the URL** `https://coroute.devmonks.space/e/` in the DLT portal (URL / CTA
   whitelisting). Operators block texts with links that are not whitelisted.
5. Note the two **Template IDs** (19 digits). Link the header to the templates, and add your SMS
   provider as a Telemarketer (MSG91 / Twilio give their TM id) so they can send for you.

### B. MSG91 (recommended for India)

1. In MSG91, add the DLT **Entity ID**, the **Sender ID** and both **DLT Template IDs**.
2. Create two **Flow templates** with the same text, using MSG91 variables in this order:
   `##name##`, `##token##`, `##lat##`, `##lng##`, `##time##` (safe now: `##name##`, `##time##`).
   Note the MSG91 template ids.
3. Server env: `MSG91_AUTH_KEY=<auth key>`, `SMS_WEBHOOK_TOKEN=<random 32+ characters>`.
   Optionally `SMS_PROVIDER=msg91`, `SMS_SENDER_ID`, `SMS_DLT_ENTITY_ID`,
   `SMS_DLT_TEMPLATE_ID_SOS`, `SMS_DLT_TEMPLATE_ID_SAFE`, `MSG91_TEMPLATE_ID_SOS` and
   `MSG91_TEMPLATE_ID_SAFE` (or set them in the admin).
4. MSG91 > Webhooks > Delivery report (JSON): set
   `https://<PUBLIC_ORIGIN>/api/sms/receipts/msg91/<SMS_WEBHOOK_TOKEN>`.
5. Web admin > Notifications > SMS: provider **MSG91**, fill in the ids, Save. The status chip
   shows **Ready**. Send a test SMS to your phone.

### C. Twilio

1. For India, register your DLT entity, header and the templates with Twilio (Console >
   Messaging > Regulatory / India DLT), or use a Messaging Service with the registered sender.
2. Server env: `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, and `TWILIO_FROM_NUMBER` or
   `TWILIO_MESSAGING_SERVICE_SID`, plus `SMS_WEBHOOK_TOKEN`. The status callback URL is sent with
   each message automatically.
3. Web admin: provider **Twilio**, Save, then send a test SMS.

### D. Check

1. Ride on a test account whose emergency contact is your second phone. Raise an SOS with the
   rider phone's "Text the group" off.
2. The second phone gets the SOS text, and its link opens the live page.
3. Cancel the SOS: "safe now" arrives.
4. The admin SMS log shows SOS and SAFE rows, SENT and then DELIVERED.

## Environment

| Variable | Default | What |
| --- | --- | --- |
| `SMS_PROVIDER` | `off` | `msg91`, `twilio`, `log` or `off` (the admin setting overrides) |
| `SMS_SENDER_ID`, `SMS_DLT_ENTITY_ID`, `SMS_DLT_TEMPLATE_ID_SOS`, `SMS_DLT_TEMPLATE_ID_SAFE` | none | DLT values (also in the admin) |
| `MSG91_AUTH_KEY` | none | Secret |
| `MSG91_TEMPLATE_ID_SOS`, `MSG91_TEMPLATE_ID_SAFE` | none | MSG91 flow template ids |
| `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN` | none | Secrets (already used by the earlier path) |
| `TWILIO_FROM_NUMBER` or `TWILIO_MESSAGING_SERVICE_SID` | none | Sender |
| `SMS_WEBHOOK_TOKEN` | none | Path token of the receipts webhook (16+ characters) |
| `SMS_MAX_PER_SOS` | 5 | Cost guard |
| `SMS_MAX_PER_USER_DAY` | 20 | Cost guard |
| `SMS_SAFE_SMS` | `true` | Send safe-now texts |
| `PUBLIC_ORIGIN` | none | https: the link in the texts and the receipts URL |

## Tests

- `gateway/test/sos_sms_355.test.js`:
  - one SMS per contact per SOS with the exact DLT text and variables of 30 characters or less;
  - DLT variable order enforced;
  - retries with backoff, and a refusal fails at once;
  - receipts (Twilio signature, MSG91 reports);
  - cancel sends "safe now" and stops pending retries;
  - per-SOS and per-day caps;
  - no numbers, names or links in the logs, and the 48 h purge;
  - MSG91 and Twilio adapters (hosts, auth, form, callback);
  - admin settings (Set / Not set), test SMS and log;
  - full path: SOS over the socket gives one SMS with a working server link, the phone's own
    link works, a repeat does nothing, and resolve sends "safe now".
- `test/sos_sms_text_356_test.dart`: the phone's text and link builder, the link code in the SOS
  message, and NEWS routing.
- `test/emergency_texts_357_test.dart` (pure): text variants and parts, dedupe per incident, retry
  schedule, daily cap, cancel before send, "safe now" follow-up, test text, status line.
- `test/emergency_texts_safety_357_test.dart`: the same through SafetyService with a fake queue
  (press grace, cancel, crash at once, denied fallback, test alarm never texts, test text).
- The earlier suites stay green: `emergency_sms_gateway.test.js`, `ride_scenarios_e.test.js` and
  `large_group_security_e.test.js` (provider `off`).
