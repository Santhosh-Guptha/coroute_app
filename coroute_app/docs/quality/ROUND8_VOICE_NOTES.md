# Round 8: voice clarity and the voice relay (notes)

The design and the measured results are in `docs/features_355/voice_clarity.md`. The build stays 3.55.0+10027.

## Files

### New

| File | What |
|---|---|
| `android/app/src/main/cpp/coroute_voice.{h,c}` | Native cleanup: 120 Hz high-pass, 16↔48 kHz polyphase resampler, RNNoise, wind-gust ducker, Strong / Normal / Off |
| `android/app/src/main/cpp/CMakeLists.txt` | Builds libcoroute_voice.so (gnu99, -O2, hidden visibility, 16 KB pages) |
| `android/app/src/main/cpp/rnnoise/` | Vendored RNNoise, BSD-3-Clause: `COPYING`, `README.vendor.md` (provenance, checksum) |
| `android/.../VoiceCodecChannel.kt` | MediaCodec Opus encoder (API 29+) and decoder (API 21+), channel `coroute/voice_codec` |
| `lib/domain/audio/voice_clarity.dart` | `NoiseReduction` setting and `VoiceChainPlan` (pure) |
| `lib/domain/audio/voice_codec_policy.dart` | Negotiation rules and the Opus frame payload (pure) |
| `lib/domain/audio/voice_jitter.dart` | Adaptive jitter buffer, `Concealer` (pure) |
| `lib/data/services/voice/voice_native*.dart` | dart:ffi binding (API, FFI implementation, web stub, conditional export) |
| `lib/data/services/voice/voice_codec.dart` | `VoiceCodecPlatform`, `OpusTx`, `OpusRx`, `SerialVoiceSender` |
| `lib/data/services/voice/voice_link.dart` | Separate `/voice` socket (process mode) |
| `gateway/src/voice_relay.js` | `VoiceRelay` (authority) and `VoiceEdge` (/voice server), tickets |
| `gateway/src/voice_relay_server.js` | Voice process entry point (forked) |
| `gateway/deploy/caddy/voice_relay.caddy` | Caddy snippet for `/voice` |
| `tool/voice_lab/` | `run_lab.sh`, `voice_lab.py` (signals and scoring), `cv_cli.c` (C harness), `dart_cleanup_cli.dart`, `ffi_check.dart`, `results.json` |

### New tests

- Dart: `test/voice_jitter_r8_test.dart` (13), `test/voice_codec_r8_test.dart` (10), `test/voice_cleanup_flags_r8_test.dart` (2). All are pure Dart and pass under `tool/pure_dart_test/run.sh`.
- Gateway: `gateway/test/voice_relay_r8.test.js` (9) and `gateway/test/voice_relay_process_r8.test.js` (3). All pass.

### Changed

- **`lib/data/services/intercom_service.dart`**: native stage, plan, Opus send path in order, codec fallback, VOICE_CAPS / VOICE_CODEC, `VoiceLink`, receive through the jitter buffer.
- **`lib/domain/audio/voice_cleanup.dart`**: new flags `spectralSuppression` and `windSuppression`, both default true. Behaviour is unchanged by default; the 12 existing DSP tests still pass.
- **`lib/data/services/settings_service.dart`**: `noiseReduction` (`noise_reduction_v1`) and `windNoiseMode` (`wind_noise_mode_v1`), appended at the end of the class.
- **`lib/presentation/widgets/intercom_dock.dart`**: the Intercom options sheet gets a "Noise reduction" segment and a "Wind-noise mode" switch.
- **`android/app/build.gradle.kts`**: `externalNativeBuild` (CMake 3.22.1).
- **`MainActivity.kt`**: registers and disposes `VoiceCodecChannel`.
- **`gateway/src/ws.js`**: only the voice blocks, each marked "Round 8 voice":
  - the import from `voice_relay.js` replaces the local `VOICE_*`, `encodeVoice` and `decodeVoice` definitions, `VOICE_MAX_FPS` and `VOICE_RATES`;
  - `VOICE_FEATURE` is appended to `FEATURES`;
  - `this.voiceRelay = new VoiceRelay(this)` follows `this.voice = new Map()`;
  - `case 'VOICE_CAPS'` sits before `case 'MIC_STATE'`;
  - the voice section's methods (`_onVoice`, `_relay`, `_endStream`, `applyRemoteVoice`, `floorOf`, …) are now one-line delegates.
- **`gateway/deploy/.env.example`**: 7 new variables.
- **`gateway/deploy/route_split.md`**: `/voice` row; `Caddyfile.vm1` regenerated with `gen_caddy_routes.js`.

## Environment variables (all optional)

| Variable | Default | What |
|---|---|---|
| `VOICE_MAX_BYTES_PER_SEC` | 48000 | Bytes per second per speaker |
| `VOICE_DROP_BYTES` | 16384 | A socket with more unsent bytes than this gets no voice (lowest priority) |
| `VOICE_FAIR_HOLD_MS` | 20000 | How long one rider may hold the floor before it yields (0 = off) |
| `VOICE_CAPS_GRACE_MS` | 3000 | A socket silent on VOICE_CAPS this long counts as an old build |
| `VOICE_RELAY_MODE` | inprocess | `process` = separate voice process |
| `VOICE_RELAY_PORT` | 3010 | Voice process port |
| `VOICE_RELAY_HOST` | 127.0.0.1 | Voice process bind address |

These existing variables are now read in `voice_relay.js`: `VOICE_MAX_FPS`, `VOICE_MAX_FRAME_BYTES`, `VOICE_STREAM_IDLE_MS`, `VOICE_MAX_STREAM_MS`.

## Routes and protocol

- **Route.** `* /voice` is LIVE: a WebSocket served by the voice process in process mode. In inprocess mode no ticket is handed out, so nothing connects to it. `GET /voice/health` is on the voice process only.
- **Socket messages:**
  - app → gateway: `VOICE_CAPS {codecs}`;
  - gateway → app: `VOICE_CODEC {groupId, codec, reason, refused?, voice?:{path, ticket, ttlMs}}`;
  - on /voice: `AUTH {ticket}` as the first message, answered with `VOICE_READY`.
- **HELLO** lists `voice2`.

## Checks run

| Check | Result |
|---|---|
| `dart analyze lib test` | No issues found |
| `dart tool/play_policy_scan.dart` | 0 hits |
| Pure-Dart tests | 25 new, all pass; the 12 existing voice_cleanup DSP tests still pass |
| C build (gcc and clang, -Wall -Wextra) | No warnings; host CMake build of the same CMakeLists works |
| FFI binding vs the C harness | Sample-identical |
| Gateway tests | 12 new, all pass |
| Full `npm test` | 1431 / 1434 pass (baseline 1355; Agent R added tests too) |

Update after the run: Agent R fixed all three (`net_compat` now expects `…, 'pos2', 'voice2'`; `rider_patch` and "durable SOS" were from the realtime work). Re-run alone, `net_compat`, `rider_patch`, `two_node_failover` and both voice relay tests: 32 / 32 pass. Agent R notes that binary voice frames are not counted by the per-socket rate limits, while `VOICE_CAPS` counts as class "other" (10/s, burst 40). That is ample: the app sends it once per JOIN, and the relay itself takes at most 10 per socket per minute.

## Requests

**Agent R (realtime)**

- ~~`test/net_compat.test.js` expected features~~: done by Agent R.
- Please keep the "Round 8 voice" delegates in ws.js as they are. Voice must stay off the outbound lanes: never route it through `_out` / `outq`.
- Not needed but welcome: when the realtime service reconnects, the intercom re-announces caps on the next SNAPSHOT. That already works as long as SNAPSHOT keeps reaching `RealtimeService.events`.

**Lead**

1. Build the APK once (QA A0). This is the first CMake / NDK native library in the app, and the Kotlin has not been compiled.
2. When enabling `VOICE_RELAY_MODE=process`, paste `deploy/caddy/voice_relay.caddy` into the vm1 site block (and the DR / staging copies) above `handle @live`. Then set `VOICE_RELAY_MODE=process` in the gateway env.
3. RNNoise attribution in the app's licences screen and the store listing: "RNNoise © 2017 Mozilla, © 2007-2017 Jean-Marc Valin, © 2005-2017 Xiph.Org Foundation, © 2003-2004 Mark Borgerding (BSD-3-Clause)".
4. **Website**: the claim "Voice cleanup takes out wind and breath" is still accurate, so no change is needed. A stronger optional line for `gateway/public/index.html`: "Noise reduction built for the road takes out wind, engine drone and road roar, so your voice comes through clear. Nothing is recorded."

**Agent J**: none.

## Device QA checklist

| # | Check |
|---|---|
| A0 | **Build.** `flutter build apk --split-per-abi`: libcoroute_voice.so is present for arm64-v8a, armeabi-v7a and x86_64. The diagnostics log shows `voice_native {available: true}`. `VoiceCodecChannel` compiles. |
| A1 | **Helmet headset at 80 km/h.** PTT with the helmet mic (SCO), Strong. The listener understands every word and hears no wind roar between words. Compare Normal and Off once. |
| A2 | **Wind.** Hands-free, phone on the mount, 60-100 km/h, gusty crosswind. Gusts between sentences are ducked, not heard as bursts. Words during a gust are not cut. Wind alone never opens the gate. |
| A3 | **Rain.** Rain on the helmet and phone does not open the hands-free gate; speech in rain stays clear. |
| A4 | **Engine idle.** At a light with a loud single or twin at idle, the engine drone is not heard by others while you talk. |
| A5 | **Two riders talking.** A talks, B presses talk: B gets "busy". After 20 s of A holding the floor, B's press takes the floor (A hears it end). Lead / sweeper are not cut. |
| A6 | **Old build in the group.** One 3.55 phone joins. Everyone still hears everyone. New phones switch to PCM (log: `voice_codec pcm16`, `codec_fallback`). The old phone leaves: the next talk is Opus again (`codec: opus1` in `talk_start`). |
| A7 | **Data saver.** Opus stays 16 kHz at 16 kbit/s (clearly better than 8 kHz PCM). With an old build present it falls back to PCM at 8 kHz, as before. |
| A8 | **Packet loss / weak signal.** Ride through a weak-4G stretch. Voice may break up but never builds a lag over about 0.6 s. Concealment covers short gaps (no clicks). It recovers within a second of the signal returning. |
| A9 | **Siren detection still works.** With hands-free talk on and Strong, play a siren near a mount phone: the siren alert arrives as before (detection uses the raw mic; RNNoise is on the intercom branch only). Also check during PTT with a headset (paused while held, resumes on release, as in 3.55). |
| A10 | **Opus encoder and decoder on devices.** Android 10+ phone: sends Opus (`talk_start codec opus1`). Android 8 or 9 phone: receives Opus, sends PCM. Check playback speed and pitch are correct (decoder 48 kHz → 16 kHz). No crackle at stream start (pre-skip). |
| A11 | **Process mode (staging).** `VOICE_RELAY_MODE=process` + Caddy snippet. The log shows `voice_link {ready: true}`. Voice works. Killing the voice process gives a short break, then talk continues over /ws. An old build still hears new phones. Leaving the ride closes the voice socket. |
| A12 | **CPU and battery per hour of talking.** One hour hands-free, Strong + Opus, screen off. Compare with Off + PCM. Note battery percent per hour and `top` CPU for the app (expected: native stage under 5 % of one little core; Opus encode about 1-2 %). Also note the mobile data used: expect about 15 MB per hour of talk for Opus vs about 115 MB for PCM at 16 kHz. |
| A13 | **SOS during heavy voice.** With 5 riders talking in turns on a weak link, an SOS reaches everyone with no added delay. |
| A14 | **Settings.** Intercom options › Noise reduction: Strong / Normal / Off and Wind-noise mode persist across restarts; Off hides Wind-noise mode. |
