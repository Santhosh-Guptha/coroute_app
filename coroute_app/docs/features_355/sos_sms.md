# SOS SMS: from the phone and from the server (3.56)

An SOS reaches the rider's emergency contacts by text in two ways:

1. **From the rider's phone**: when the SOS cannot reach the group over the internet.
2. **From the server**: through an SMS provider (MSG91 or Twilio), when the SOS reaches the
   gateway (directly, or relayed by another rider's phone) and the phone did not text the
   contacts itself. When the SOS is resolved or cancelled, the same contacts get a "safe now"
   text.

Ride Guardian watchers get the SOS and the arrival through browser push, as before
(`guardian_push.js`, checked every 15 s; the emergency push is sent with high urgency). The
arrival words are the editable template "Guardian: arrived safely".

## 1. From the rider's phone (app)

`lib/data/services/safety_service.dart` `_smsRound`, `lib/domain/safety/sms_plan.dart`:

- **Who**: the emergency contact, then the ride's lead and sweeper, then the nearest riders.
  - `SmsPlanner`: never the sender, never the same number twice, at most
    `smsMaxRecipients`, within the phone's text budget.
  - An offline solo ride texts the contact without waiting for the "Text the group" opt-in.
- **Text**: name, time, the **live link**, the coordinates as text, plus the map link and ride
  name only while the text still fits one SMS part. Example:
  `CoRoute SOS: Kiran needs help at 14:05. Live: https://coroute.devmonks.space/e/Ab3dEf6hIj9lMn0pQr2tUv Lat 12.97160 Lng 77.59456`
  - The live link code (`PendingSos.linkToken`, 22 random characters made when the SOS is
    raised) is stored with the pending SOS and sent with it as `smsLinkToken`.
  - When the SOS reaches the gateway, directly or relayed, the gateway registers it
    (`EmergencySmsGateway.registerClientLink`). From then on `/e/<code>` shows the rider's live
    position for 30 minutes or until the alert is closed.
  - Before that the link shows the "link has expired" page, and the coordinates in the text
    still work.
  - An SOS stored by an older version has no code and gets the map link text as before.
- **How**: the Play build (and the website APK, which is the same build) has no `SEND_SMS`
  permission. The text goes through the phone's messages app with every recipient and the text
  filled in, and the rider or a bystander presses Send.
  - Android does not let an app open another app from the background. The automatic round
    therefore only shows a waiting status (`composerWaiting`), and **Text the group now** opens
    it once the phone is in hand.
  - A build with `SEND_SMS` granted sends directly. It waits for the sent report of each part,
    up to 20 s, and stops at "no service".
- **Lock screen**: when the SOS screen is shown over the lock screen, tapping "Text the group
  now" asks Android to unlock first (`KeyguardManager.requestDismissKeyguard`, `SmsChannel.kt`).
  The messages app then opens. If the rider cancels the unlock, it can be tapped again.
- **Retries when offline**: the messages app queues the text and sends it when there is signal.
  - The pending SOS itself is kept on disk and resent over the internet (same `clientId`, so
    never duplicated) as soon as the phone is back online.
  - Once it arrives, the server texts any contact the phone could not reach (below).
- **Status**: the SOS screen shows the text status, for example "Texted 2 of 3"
  (`SmsFallbackStatus`).

## 2. From the server (gateway)

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
- The earlier suites stay green: `emergency_sms_gateway.test.js`, `ride_scenarios_e.test.js` and
  `large_group_security_e.test.js` (provider `off`).
