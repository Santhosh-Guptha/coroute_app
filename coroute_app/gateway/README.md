# CoRoute Gateway

Single Node.js service that fronts the Oracle Autonomous Database for the CoRoute
mobile app and relays real-time telemetry, chat, alerts and **voice** between the
riders of one convoy.

```
Flutter app  ──HTTPS /api/*──▶  Caddy (TLS)  ──▶  gateway :3000  ──SODA REST──▶  Oracle ADB (Always Free)
             ──WSS   /ws   ──▶             ──▶   (rooms, voice relay, write-behind persistence)
```

* **Auth**: register / login (bcrypt) or Google Sign-In (ID token verified server-side) → JWT.
* **Rooms**: a socket is bound to exactly one convoy after a membership-checked `JOIN`;
  every broadcast is room-scoped, so one group can never hear or see another.
* **Voice**: PCM16 frames relayed as binary WebSocket messages to the room or to one
  chosen rider (`to`). Floor control for group talk. No audio is ever stored.
* **Persistence**: per-rider documents (no whole-convoy overwrites), write-behind for
  telemetry, immediate for messages/alerts/config.
* **Housekeeping**: stale convoys auto-end, GPS traces are stripped after
  `RETENTION_ENDED_CONVOY_DAYS`, accounts and trip records are kept forever,
  and a keep-alive ping stops the Always-Free DB from being paused.

## Run locally without a database
```
ORACLE_SODA_URL=memory ORACLE_USER=x ORACLE_PASSWORD=x JWT_SECRET=$(openssl rand -base64 48) npm start
```

## Tests
```
npm test
```

See `deploy/RUNBOOK.md` for production deployment on the OCI VM.

## Deploy notes
* Every setting is an environment variable read by `src/config.js`; `deploy/.env.example` lists
  them all (secrets left empty). Copy it to `/etc/coroute/gateway.env` (chmod 600) and fill it in.
* `REVIEW_PHOTO_DIR`: private folder for photos riders attach to trip reviews. It must be outside
  `public/`, persistent and backed up. Unset, it is `<gateway>/data/review-photos`, which is inside
  the service's `ReadWritePaths`; a folder elsewhere must be added to `ReadWritePaths=` in
  `deploy/coroute-gateway.service` (the unit runs with `ProtectSystem=strict`). Deleting an account
  deletes that rider's review photo files too.
* Emergency SMS providers (`TELEPHONY_*`, `TWILIO_*`, `WHATSAPP_*`, `INFOBIP_*`, `AWS_SNS_*`) stay
  disabled while their keys are empty.
* `PAYMENTS_ENABLED` defaults to on in production; set it to `false` only on a staging box.
* Coupons: the launch coupons `WELCOME50`, `CAPTAIN100` and `RIDERFREE` are created once in the
  coupon store on first start (bound to plans, once per rider, with a total limit and an end date)
  and are then managed like any other coupon in the admin console; pausing, editing or archiving
  one is never undone by a restart.
* Passwords are hashed with bcrypt cost 12; older hashes are upgraded at the rider's next sign-in.
