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
