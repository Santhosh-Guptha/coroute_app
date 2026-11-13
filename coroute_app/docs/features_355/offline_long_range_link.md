# Offline group link: Bluetooth LE Long Range rider mesh (Round 10, on 3.55.0+10028)

The owner asked for this: "free for riders, no extra hardware: an offline group link that covers about 1 km". The design
the owner approved:

1. Bluetooth 5 LE Long Range (Coded PHY) where the phone supports it.
2. Multi-hop relay through riders.
3. Any phone with mobile data bridges the whole group to the server.
4. Store-and-forward so nothing is lost across gaps, with voice degrading to walkie-talkie clips.
5. A chain-keeper that warns before the chain breaks.
6. Fully automatic: on when signal drops, off when it returns, no hotspot.

Test notes, the file list, simulation numbers and the device checks are in docs/quality/ROUND10_MESH_NOTES.md.

## 1. What the rider sees

- Nothing to switch on. In a group ride the phone keeps a slow, low-power Bluetooth beacon going (standby). When the
  ride connection has been down for 8 s (3 s with no network at all), the link switches itself to **offline** mode.
  It goes back to standby once the server link has been healthy for 10 s.
- A small chip on the ride screen: **"Offline link: 5 riders, 2 hops"**. A phone that still has signal and is
  carrying riders who lost it shows **"Offline link: bridging 2 riders"**.
- Positions of riders reached over the link appear on the map as before (the 3.55 mesh marker and hop count).
- An SOS reaches every rider the chain reaches, and reaches the server (and from there the server's SMS to contacts)
  as soon as **any** rider in the chain has data.
- Push-to-talk works over the link. When the path is too long, too slow or broken, the talk is recorded as a
  **walkie-talkie clip** (up to 15 s), carried rider to rider, and plays on arrival with **"Voice message from Ravi"**.
- The chain-keeper: the rider in front of a stretching gap hears "Signal chain stretching, ease off a little."; the lead
  hears "Group link stretched behind Ravi, slow down." At most one warning per gap every 2 minutes, never over an SOS
  or a crash alarm, and through the same warning scheduler as bends and hazards (round 7).
- The group panel shows **"Offline link: 4 of 6 phones support long range"**.

## 2. Honest range expectations

| Radio | Realistic per hop, bike to bike | Notes |
|---|---|---|
| **Coded PHY (S8)**, both phones support it | **200-600 m** | Phones in pockets / tank bags, riders' bodies in the way. Open, flat roads with line of sight: more (up to about 1 km). Towns, bends, cuttings, trucks between bikes: less (100-200 m). Depends heavily on the phone (antenna, transmit power +0 to +10 dBm, sensitivity -100 to -106 dBm). |
| 1M PHY (phones without Coded PHY) | 50-150 m | The link still works, but needs a denser group. |
| Shared Wi-Fi / hotspot (UDP) | the hotspot's range | The 3.55 path, kept. |

**1 km is a group property, not a phone property.** Six riders strung over 1 km with Coded PHY phones usually form a
2-4 hop chain. Two riders 1 km apart with nobody between them are **not** connected. Riders without Coded PHY phones
shorten the hops around them. The chain-keeper exists because of this.

Coded PHY needs Bluetooth 5 hardware AND the phone maker enabling it (`isLeCodedPhySupported` and
`isLeExtendedAdvertisingSupported`). Many recent mid- and high-end Android phones have it; many budget phones do not.
The app measures it on every phone and reports it to the group (section 1). iPhones are not part of the link (the app is
Android-first; the website already says so).

## 3. How it works

```
 rider A (no signal)        rider B (no signal)        rider C (has data)          gateway
 ┌──────────────┐  Coded   ┌──────────────┐  Coded    ┌──────────────┐  socket   ┌──────────┐
 │ MeshNode     │ ───────▶ │ MeshNode     │ ────────▶ │ MeshNode     │ ────────▶ │ mesh_    │
 │ router/store │ ◀─────── │ relays once  │ ◀──────── │ + bridge     │ ◀──────── │ bridge.js│
 └──────────────┘  PHY     └──────────────┘  PHY      └──────────────┘ MESH_*    └──────────┘
```

### 3.1 Radio (android/.../LongRangeBle.kt, MeshBleChannel.kt; Dart: lib/data/services/offline_link/)

- **Discovery.** A 13-byte beacon as service data under CoRoute's own 128-bit UUID: group tag, rider short id, sequence,
  capability bits, L2CAP PSM and a 4-byte MAC (keyed from the ride key, bound to the minute, so it cannot be forged or
  replayed later).
  - Phones with Coded PHY: an **extended, connectable advertising set on PHY_LE_CODED** (primary and secondary,
    `setLegacyMode(false)`), plus a slower legacy 1M set so phones without Coded PHY still find them.
  - Other phones: legacy advertising on 1M (UUID in the advertisement, beacon in the scan response).
  - Scanning: `ScanSettings.setLegacy(false)`, `setPhy(PHY_LE_ALL_SUPPORTED)` (API 26+), with hardware filters on the
    UUID / the group tag (unfiltered scans are paused by Android with the screen off).
- **Data.** One link per neighbour pair, up to 4 (the lower rider id opens it; the other side after 10 s if needed).
  - GATT on every API level (write-without-response + notify, MTU 247, fragmented), opened with
    `connectGatt(..., PHY_LE_CODED_MASK)` and `setPreferredPhy(CODED, CODED, PHY_OPTION_S8)` when both phones support it.
  - On Android 10+ an **L2CAP CoC** channel (`listenUsingInsecureL2capChannel` / `createInsecureL2capChannel`) is opened
    over the same link and preferred for data. "Insecure" means no pairing dialog: every frame is already encrypted
    and authenticated end to end with the ride key.
  - API 26-28: GATT only. API 24-25: GATT on 1M.
- **RSSI**: every beacon, plus a remote-RSSI read every 2 s on links where this phone is the GATT client.
- **Second path**: the existing UDP broadcast transport on its own port (42425) for phones that share Wi-Fi or a
  hotspot. Wi-Fi Aware was considered and left out (see the notes: support is rarer than Coded PHY, it needs another
  permission and its own session handling).

### 3.2 Routing (lib/domain/mesh/, pure Dart, unit tested)

- **Secure frame** (`mesh_frame.dart`): 33-byte header + AES-256-GCM payload + 16-byte tag.
  - The header's first 22 bytes are authenticated: group tag, class, origin, boot id, sequence, origin time, initial TTL.
  - The relay header (TTL left, last relay id, last relay position) is rewritten by every hop.
  - The nonce is origin | boot (random per app start) | sequence: unique per key.
  - AES and GCM are pure Dart (`crypto/aes_gcm.dart`, checked against the NIST vectors), because the app has no crypto
    package and pub cannot be fetched. The gateway opens the same frames with Node's `aes-256-gcm`.
- **Group-scoped flooding** (`mesh_router.dart`):
  - Every rider relays a fresh frame once, after a short back-off. Edge riders (weak reception) relay first.
  - Deduplication and the hop limit (TTL: SOS 8, alerts 6, positions 5, voice 4; capped at 8).
  - **Counter-based suppression**: a relay is cancelled after hearing the same frame relayed 2 times (positions),
    1 time (voice) or 3 times (alerts) while waiting.
  - **Progress suppression**: no relay when the rider we heard it from is already 50 m+ farther from the origin.
  - An SOS is never suppressed.
- **Priority classes**: SOS > alerts > positions > voice > chat.
  - Strict priority with a byte budget per class out of the link's airtime (alerts 15 %, positions 35 %, voice 50 %,
    chat 10 %).
  - SOS is never budget-limited and always goes first, so **voice can never starve SOS** (tested).
  - Positions are latest-only in the queue. Live voice older than 300 ms is dropped. Live voice goes before stored clip
    chunks.
- **Compact payloads** (`mesh_messages.dart`): a position is 19 bytes with the Round 8 pos2 scales (1e-5 degrees,
  dm/s, whole degrees). With the frame overhead a position frame is about 68 bytes.
- **Authentication and replay protection**:
  - The ride key (32 bytes) comes from the gateway at ride start (`MESH_KEY`, derived with HMAC-SHA256 from
    `MESH_KEY_SECRET`, the group and the ride's creation time). It is kept in the phone's secure storage for the ride
    and deleted when the ride ends.
  - Riders outside the ride can neither read nor inject.
  - Replay: a frame is accepted once and only while fresh for its class (SOS 6 h, voice / alerts 15 min, positions
    5 min). The id cache is bounded, and evicting an id raises a low-water mark so it can never come back.
  - **Limit, said plainly:** the key is shared by the ride's riders, so a rider of the same ride could forge a frame
    "from" another rider of that ride. Two consequences:
    - a mesh "SOS resolved" never closes an alert on the server;
    - a forged SOS errs on the side of alerting.
    Per-rider signatures (Ed25519) are the next step if this matters.
- **Neighbour table** (`mesh_neighbors.dart`): RSSI (smoothed and the trend in dB/s), capabilities, beacon loss, every
  rider's last fix and hop distance.

### 3.3 Store-and-forward (`mesh_store_forward.dart`)

- Every rider carries SOS, SOS acknowledgements, alerts, the **latest** position of each rider, clip chunks and chat.
- The buffer is bounded at 400 items and 640 KB. Eviction order: chat, positions, clips, alerts. SOS is never evicted
  for space.
- Everything is offered again to every new link (a rider back after 30 s+), and SOS every 20 s to whoever is in range
  for its first 10 minutes. This is epidemic delivery within the group.
- **Its own SOS is resent on a 2 / 4 / 8 / 15 / 30 s back-off until ANYONE acknowledges it**: a rider who heard it
  (the closest ones answer first, the others hear the answer and stay quiet), or the server through a bridge.
- Missing clip chunks are asked for (`MeshClipNack`) and re-sent by whoever holds them.

### 3.4 Internet bridging (gateway/src/mesh_bridge.js; app: mesh_bridge_client.dart)

- After every JOIN the app sends `MESH_HELLO {caps}`. The gateway answers with `MESH_KEY` and a room-wide `MESH_CAPS`
  (the "4 of 6 phones" line).
- A phone with a healthy socket that hears riders without signal becomes a **bridge**.
  - It forwards their sealed SOS and position frames in `MESH_BRIDGE {f: [...]}` (an SOS at once, positions once a
    second).
  - The gateway opens each frame with the ride key, checks freshness and replay, and maps the origin to a rider of the
    room:
    - **position**: the rider shows as connected with a `viaBridge` flag and presence ONLINE. If the rider has its own
      socket, the direct position wins and nothing is doubled. Presence goes back to NO_SIGNAL 30 s after the bridged
      positions stop.
    - **SOS**: stored exactly like an SOS from the rider's own socket, with emergency dispatch. It uses the phone's own
      clientId, so a copy arriving later (another bridge, or the rider's own socket) is the same alert.
    - The gateway answers `MESH_BRIDGE_ACK`, and the bridge puts a "server has it" acknowledgement into the mesh.
- **Downlink.** The bridge injects the server's positions of riders the mesh does not hear, and alerts raised outside
  the mesh, as *proxied* frames. A rider without signal still sees the whole group and every SOS.
- Voice is **not** bridged in this round (clips stay in the mesh).
- `MESH_BRIDGE` is a safety type for the generic limiter (it can carry an SOS). The module caps it at 48 frames per
  message and 40 non-SOS frames a second per socket.
- With the admin switch `offlineMesh` off, only SOS frames are accepted, in the app and on the gateway.

### 3.5 Voice over the mesh (mesh_voice.dart, mesh_voice_link.dart, intercom_service.dart)

- Capture is unchanged: the shared ride mic → **RNNoise chain** → Dart post-stage, as in Round 8. While the socket is
  down and the link runs, the intercom hands its START / FRAME / END to the link instead of the socket.
- **Live**: Opus at **12 kbit/s** (8 kbit/s on a slow link), two 40 ms frames per mesh frame. This is used when the
  estimated path latency is ≤ 450 ms (100 ms + 70 ms per Coded hop), the loss is ≤ 20 % and the voice budget fits.
  Phones without an Opus encoder: IMA ADPCM at 8 kHz (32 kbit/s), only to a strong near neighbour on a fast PHY.
- **One speaker at a time** (`MeshFloor`), the same rules as the gateway floor:
  - the Lead / sweeper may cut in;
  - fair share after 20 s;
  - a floor with no frame for 1.5 s is free;
  - simultaneous starts: priority first, then the lower rider id.
  A press while the floor is busy records a clip instead.
- **Clips**: when there is no live path, the path is too slow or lossy, or this rider lost the floor mid-talk. Up to
  15 s, chunked (≤ 420 bytes), stored and forwarded, played on arrival at real-time pace with the
  "Voice message from …" chip, after any live talk ends.
- Received audio goes through the intercom's own jitter buffer, Opus decoder, ducking and limiter (the link delivers
  the same VoicePacket the gateway would).

### 3.6 Chain-keeper (mesh_chain_keeper.dart)

- Each phone watches only its own link to the rider right behind it (convoy order: distance from the lead).
- It predicts the time to break from the RSSI trend (towards -100 dBm Coded / -92 dBm 1M) and from the growing gap
  (towards 450 m Coded / 150 m 1M).
- It needs a real trend (RSSI falling ≥ 0.25 dB/s or the gap growing ≥ 0.4 m/s) and a predicted break within 25 s.
- The rider in front of the gap is warned. The lead gets a mesh alert and hears the note (rate-limited per rider,
  90 s).
- Everything goes through `RoadCareService.mayAdviseFallingBehind` (round 7 WarningScheduler), and nothing is spoken
  while an emergency is open.

## 4. Battery (paper estimate; to be measured: QA M9)

| Mode | Radio settings | Extra current (radio + CPU wake-ups) | Per hour on a 4,500 mAh phone |
|---|---|---|---|
| Off (no group ride) | nothing | 0 | 0 |
| Standby (group ride, online) | LOW_POWER scan (10 % duty), beacon every 1 s, no links | about 1.5-3 mA | about 0.05 % |
| Bridge | BALANCED scan (25 %), beacon 250 ms, up to 3 links | about 6-12 mA | about 0.2 % |
| Offline, moving | LOW_LATENCY scan (100 %), Coded beacon 250 ms + legacy 500 ms, up to 4 links, router tick 20 ms | about 15-40 mA | about 0.3-0.9 % |
| Offline, stopped or low battery | BALANCED scan, 3 links, positions every 5-6 s | about 6-15 mA | about 0.15-0.35 % |
| Offline with own SOS | LOW_LATENCY, beacon 100 ms (SOS overrides low battery) | about 15-45 mA | about 1 % |

The ride itself (GPS, screen, foreground service) costs far more, about 150-400 mA. The offline link's share is small,
but the scan wake-ups on some phones may be larger than this table. Measure (QA M9). Voice over the link adds the
intercom's existing cost.

## 5. Privacy

- Nothing new is collected. Over the link the phones exchange what the ride already shares (position, speed, battery,
  SOS, voice), only with riders of the same ride, encrypted and authenticated with a per-ride key.
- The beacon carries no name, no phone number and no position: a group tag, a rider short id (a hash), capability bits
  and a MAC. Outsiders cannot tell which ride it belongs to. The short id is stable for the account, so a determined
  observer could notice that the same phone passes by again during the ride. The beacon is on only during a group ride.
- RSSI is used for link quality and the chain-keeper only. It is never used to locate anyone, and the scan is declared
  `neverForLocation`.
- Voice is never recorded on a server. A walkie-talkie clip lives only in the riders' phones' memory, up to 10 minutes,
  and is deleted at ride end.
- Through a bridge the gateway receives the same position and SOS data the rider's own socket would have sent. It
  keeps them the same way, and the same retention rules apply.
- The ride key lives in the phone's secure storage during the ride and is deleted when the ride ends.
