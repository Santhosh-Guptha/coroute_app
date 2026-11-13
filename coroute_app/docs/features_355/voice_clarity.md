# Voice clarity: RNNoise, Opus and the voice relay (Round 8, on 3.55.0+10027)

The owner asked for this: "voice should be very clear, and suppressing noise and background noises should work excellent". It is also step 1 and step 2 of the high-traffic plan (docs/infra/HIGH_TRAFFIC_PLAN_v3.57.md, section 7).

Voice rules do not change. Voice is never recorded: the gateway keeps only a session log line (who, when, how long). It goes to the group only.

## 1. What changed, in one table

| Area | Before (3.55) | Now |
|---|---|---|
| Noise reduction | Pure-Dart chain: 140 Hz high-pass, STFT Wiener filter, breath and wind classes, gate, AGC | **RNNoise** (Xiph, BSD-3) in a small native library, with a 120 Hz high-pass, a 16↔48 kHz resampler and a fast wind-gust ducker. The Dart stage keeps the voice gate, breath cut, AGC and limiter. The 3.55 chain is the fallback when the library is missing. |
| Settings | "Clean up my voice" (always on) | Intercom options › **Noise reduction: Strong (default) / Normal / Off**, plus **Wind-noise mode** (default on) |
| Codec | Raw PCM16: 32 KB/s at 16 kHz, 16 KB/s in data saver | **Opus** over MediaCodec at 24 kbit/s (16 kbit/s in data saver), always 16 kHz wideband, about 4 KB/s on the wire. PCM16 when an old build is in the group, or when the phone has no encoder. |
| Receive | A fixed queue: play from 2 frames, 600 ms cap | Adaptive jitter buffer (40-120 ms), loss concealment and drift control |
| Gateway | Voice code inside ws.js | `gateway/src/voice_relay.js`. Voice is the **lowest** priority on the live socket, with per-speaker caps, talk-time fairness and metrics. An optional separate voice process can serve `/voice`. |

## 2. Capture and the siren detector (kept working)

The ride already has **one shared microphone** (`RideMicHub`, `ride_mic_hub.dart`, record plugin, 16 kHz, 20 ms frames). Its `MicPlan` already does what item 1 of the brief asks:

| Need | Android source | OS effects (NS / AEC / AGC) | Bluetooth SCO (helmet mic) |
|---|---|---|---|
| Talk only (siren alerts off) | `VOICE_COMMUNICATION` | on, where the phone has them | on: helmet / wired headset mic |
| Push-to-talk held with a headset | `VOICE_COMMUNICATION` | on | on (only while held) |
| Siren detection (alone, or with hands-free talk, or PTT without a headset) | `MIC` (raw) | off | off |

The record plugin attaches the platform `NoiseSuppressor`, `AcousticEchoCanceler` and `AutomaticGainControl` when `noiseSuppress` / `echoCancel` / `autoGain` are set and the device has them. That is the `processed` plan above. Nothing changed here.

**Siren detection keeps its own raw path.** OS noise suppression would erase a siren as stationary noise. RNNoise would erase it too: a siren is not speech. So RNNoise runs **only on the intercom branch**, after the hub has handed the raw frame to the detector (`IntercomService._onHubFrame`). The detector never sees processed audio:

- detection frames still come from the raw `MIC` source;
- headset or processed frames are still flagged and skipped by the detector, as before.

The record plugin has no "pre-effects tap", so the brief's option of a tap before the effects is the existing raw plan.

## 3. Noise suppression

### Native stage: `android/app/src/main/cpp/coroute_voice.c` (libcoroute_voice.so)

Per 10 ms of 16 kHz input:

1. **Wind-gust features** on the raw input. The detector looks at energy below 100 Hz (4th-order low-pass): its share of the total, and how far its level, smoothed over about 35 ms, rises above a slow average of about 2 s. It also counts clipping. It needs no FFT.
2. **2nd-order Butterworth high-pass at 120 Hz**: removes wind rumble and engine drone below the voice.
3. **×3 polyphase upsampling to 48 kHz**: 121-tap Kaiser-windowed sinc (β 8), cut-off 7.3 kHz.
4. **RNNoise**: one 480-sample frame per 10 ms. It gives a voice probability (VAD) for free.
5. **÷3 decimation** back to 16 kHz with the same filter.
6. **Normal only**: the time-aligned high-passed input is added back at −12 dB. This caps suppression near 12 dB and sounds more natural.
7. **Wind ducking** (Wind-noise mode): −20 dB in Strong, −12 dB in Normal.
   - Attack is 3 ms, release 120 ms.
   - There is **no ducking while RNNoise hears a voice** (VAD > 0.6 in the current or previous block), so words are never ducked.
   - The detector works on input that is 12.5 ms ahead of the output, so the duck is in place before a gust reaches the output.

Added latency is **200 samples = 12.5 ms**: 10 ms for RNNoise plus 2 × 60 samples at 48 kHz for the filters. The lab measured 196 samples by cross-correlation (filter phase).

The library is bound from Dart with **dart:ffi** (`lib/data/services/voice/voice_native_ffi.dart`). Calls are synchronous on the audio path, with no platform-channel hop and no JNI. Only the `cv_*` API is exported (`-fvisibility=hidden`). If the library is missing, has the wrong ABI version, or the platform is web (stub), the app falls back to the 3.55 pure-Dart chain.

### Dart post-stage: `VoiceCleanup` (lib/domain/audio/voice_cleanup.dart)

With the native stage running, `spectralSuppression` and `windSuppression` are off. The Wiener filter would double-process, and the lab found the 20 ms wind class firing on about 10 % of **clean-speech** blocks (nasals and other low, weakly voiced sounds), cutting them by 18 dB. Still running:

- the hands-free voice gate (it now opens far more reliably in noise: 485 vs 85 of 1343 blocks in pink noise at 0 dB, because it sees RNNoise's output);
- the breath cut;
- AGC to −20 dBFS;
- the −1 dBFS limiter.

The plan logic is `VoiceChainPlan.forChoice` (lib/domain/audio/voice_clarity.dart):

| Setting | Native library loaded | Chain |
|---|---|---|
| Strong (default) | yes | RNNoise full + wind ducker (Wind-noise mode) → gate / breath / AGC / limiter |
| Normal | yes | RNNoise with −12 dB of the original mixed back + wind ducker → gate / breath / AGC / limiter |
| Strong / Normal | no | 3.55 Dart chain (Wiener on); Wind-noise mode drives its wind class |
| Off, or admin switch `voiceCleanup` off | either | Off: gate / AGC / limiter only. Admin off: raw frames and the old loudness VOX, as in 3.55. |

## 4. Measured results (tool/voice_lab, this machine)

How to rerun: `tool/voice_lab/run_lab.sh`. It builds the C code with the host gcc, generates the audio, runs every variant, checks the FFI binding and writes `tool/voice_lab/results.json`.

### Test signals

- **Speech**: 26.9 s of flite TTS from 4 voices (male and female), 6 riding phrases with pauses, active speech at −26 dBFS.
- **Noises**, mixed at 0 and 5 dB broadband SNR:
  - **pink** and **brown**;
  - **wind**: low-passed 1/f^1.6 noise with gusts of +6 to +14 dB lasting 0.3-1.5 s;
  - **engine**: a 33-57 Hz twin wandering through 32 harmonics, flutter and mechanical noise;
  - **road roar**: band-limited 60-1500 Hz;
  - **traffic**: pink bed, passing-vehicle swooshes and a two-tone horn;
  - **highway mix**: wind + engine + road roar.

### Metrics

- **SNR**: spectral (phase-blind) signal-to-error in 60-7000 Hz, 32 ms frames, best gain. Speech distortion counts as error, so the measure is conservative and saturates around 15-21 dB.
- **Pause cut**: noise power removed in speech pauses.
- **STOI**: intelligibility index, 0-1 (pystoi, MIT).

### Results by noise

Each cell is SNR out / pause cut / STOI in→out.

| Noise (broadband SNR) | In-band SNR in | 3.55 Dart chain | **Strong**, native only | **Strong as shipped** (+ Dart post-stage) | **Normal** |
|---|---|---|---|---|---|
| Highway mix 0 dB | +5.5 dB | +1.7 / 33 dB / 0.87→0.71 | +12.2 / 27 dB / 0.87→0.90 | +10.5 / 29 dB / 0.87→0.89 | +12.2 / 16 dB / 0.87→0.90 |
| Highway mix 5 dB | +10.5 dB | +5.0 / 33 dB / 0.93→0.80 | +14.7 / 25 dB / 0.93→0.94 | +11.8 / 27 dB / 0.93→0.93 | +15.0 / 16 dB / 0.93→0.94 |
| Engine 0 dB | +3.0 dB | +1.9 / 36 dB / 0.88→0.72 | +12.5 / 29 dB / 0.88→0.91 | +10.8 / 31 dB / 0.88→0.91 | +12.4 / 17 dB / 0.88→0.91 |
| Engine 5 dB | +7.9 dB | +5.2 / 37 dB / 0.93→0.81 | +15.8 / 26 dB / 0.93→0.95 | +12.4 / 28 dB / 0.93→0.94 | +15.8 / 17 dB / 0.93→0.95 |
| Road roar 0 dB | +2.0 dB | −0.3 / 20 dB / 0.78→0.64 | +9.1 / 23 dB / 0.78→0.82 | +8.3 / 26 dB / 0.78→0.82 | +8.7 / 13 dB / 0.78→0.82 |
| Road roar 5 dB | +6.7 dB | +2.3 / 21 dB / 0.87→0.72 | +13.1 / 22 dB / 0.87→0.91 | +11.0 / 25 dB / 0.87→0.90 | +12.8 / 13 dB / 0.87→0.91 |
| Pink 0 dB | +5.4 dB | +0.7 / 24 dB / 0.77→0.59 | +12.5 / 28 dB / 0.77→0.82 | +10.7 / 30 dB / 0.77→0.82 | +12.1 / 16 dB / 0.77→0.83 |
| Pink 5 dB | +10.4 dB | +2.8 / 24 dB / 0.86→0.70 | +15.1 / 27 dB / 0.86→0.89 | +12.0 / 30 dB / 0.86→0.88 | +15.1 / 16 dB / 0.86→0.89 |
| Traffic 0 dB | +2.0 dB | −0.2 / 12 dB / 0.74→0.60 | +6.9 / 8 dB / 0.74→0.78 | +5.8 / 8 dB / 0.74→0.77 | +6.4 / 5 dB / 0.74→0.78 |
| Traffic 5 dB | +6.9 dB | +3.8 / 11 dB / 0.82→0.72 | +11.7 / 7 dB / 0.82→0.84 | +9.9 / 8 dB / 0.82→0.84 | +11.1 / 4 dB / 0.82→0.85 |
| Wind gusts 0 dB | +22.8 dB\* | +9.1 / 46 dB / 1.00→0.87 | +17.2 / 34 dB / 1.00→0.98 | +12.6 / 34 dB / 1.00→0.97 | +17.9 / 30 dB / 1.00→0.99 |
| Brown 0 dB | +35.7 dB\* | +9.6 / 50 dB / 1.00→0.87 | +20.9 / 38 dB / 1.00→0.99 | +13.6 / 38 dB / 1.00→0.98 | +20.9 / 35 dB / 1.00→0.99 |

\* Wind and brown noise sit mostly below 60 Hz, so the in-band SNR is already high. For these two, read the pause cut and STOI: the noise goes and intelligibility stays intact.

### Reading the results

- **Strong vs the 3.55 chain.** In the mixed riding noises (highway, engine, road, pink, traffic at 0 dB), SNR is **+7 to +11 dB** better and STOI **improves** (0.87→0.89-0.90 on the highway at 0 dB). The 3.55 Wiener chain **lowered** STOI in every case (0.87→0.71), even though it cut more in pauses. Its gains also hurt the speech.
- **Clean speech through the shipped Strong chain** changes level by **−1.4 dB**. The 3.55 chain changes it by −1.4 dB too, and RNNoise alone by −0.6 dB.
- **Wind-gust detector.**
  - It flags 0 % of clean-speech blocks, 2 % of steady pink noise, and 14.5 % of a gusty wind recording (the gust peaks).
  - Its gain shows up in the pause cut for gusts: 34 dB with it, 33 dB without.
  - It stays off during speech, so it does not cost speech quality: STOI is 0.98 with it and 0.99 without.
- **Traffic is the hardest case**: horns and passing vehicles are not stationary. RNNoise still adds about 5 dB and keeps STOI.

### CPU, latency and the FFI check

| What | Result |
|---|---|
| CPU, Strong chain (native) | **164 µs per 10 ms of audio = 1.6 % of one core** (Intel Xeon 2.1 GHz, gcc -O2, best of 3; 3.6-4.4 % when the machine was shared). Expect about 3-6 % of a little ARM core and about 1.5-2 % of a big one. Measure on device (QA A12). |
| CPU, 3.55 Dart chain (desktop JIT) | 70-90 µs per 10 ms |
| CPU, Dart post-stage | about 70 µs per 10 ms (desktop JIT) |
| Latency | native 200 samples (12.5 ms) + Dart STFT 192 samples (12 ms) |
| Library | libcoroute_voice.so: 154 KB on x86-64 (host CMake build, same CMakeLists as the APK) |
| FFI binding vs the C harness | **sample-identical** on the 27 s highway mix (`ffi_check.dart` loads the host build through the app's own binding) |

## 5. Opus

### Encoder and decoder

The Kotlin side is `android/.../VoiceCodecChannel.kt` (channel `coroute/voice_codec`). The Dart side is `lib/data/services/voice/voice_codec.dart`.

**Encoder** (Android 10+):

- `audio/opus`, 16 kHz mono, one 20 ms packet per input frame;
- `KEY_BIT_RATE` 24 000 (16 000 in data saver);
- `KEY_BITRATE_MODE` VBR when `isBitrateModeSupported`;
- `KEY_COMPLEXITY` 5, clamped to the encoder's range;
- codec-config buffers (OpusHead) are skipped.

**MediaCodec has no public key for Opus in-band FEC or DTX**, so neither is set. Instead:

- the voice gate already sends nothing in silence, which does the job of DTX;
- the receiver conceals lost frames;
- the relay drops voice whole frames at a time (TCP never loses packets inside a frame).

**Decoder** (Android 5+):

- configured with `csd-0` (OpusHead: 1 channel, pre-skip 312), `csd-1` (pre-skip in ns) and `csd-2` (80 ms seek pre-roll), as MediaExtractor would;
- the platform decoder outputs 48 kHz, decimated 3:1 in Kotlin (63-tap Blackman-windowed sinc) to 16 kHz;
- one decoder, flushed for every new stream.

### Wire format and negotiation

**Wire.** The START header has `codec: 'opus1', sampleRate: 16000`. A FRAME payload is 2 packets (40 ms), each as `[length u16 BE][packet]`.

Two per frame because a single 20 ms packet at 20 kbit/s is about 50 bytes, smaller than the per-message WebSocket + TLS + TCP/IP overhead of about 70-100 bytes. To Opus listeners the relay sends a compact frame header `{streamId, from, seq, codec}`, about 60 bytes instead of about 150.

**Negotiation** (pure rules in `lib/domain/audio/voice_codec_policy.dart`):

1. The gateway's HELLO lists the feature `voice2`.
2. After every JOIN (SNAPSHOT), the app sends `VOICE_CAPS {codecs: ['opus1','pcm16']}`. It sends `['pcm16']` only when it has no decoder. "opus1" means "can **receive** Opus".
3. The relay answers `VOICE_CODEC {codec}`:
   - `opus1` while every rider in the room can receive Opus;
   - `pcm16` as soon as one cannot. That is an old build (no VOICE_CAPS within `VOICE_CAPS_GRACE_MS`, 3 s) or a phone without the decoder.
   - It announces again on every change: an old build joins or leaves.
4. The app **sends** Opus only when the group codec is `opus1` **and** it has the encoder (Android 10+). Android 5-9 phones receive Opus and send PCM.
5. **PCM fallback rule (no transcoding).**
   - An Opus START while the group needs PCM is refused with `VOICE_CODEC {codec:'pcm16', refused:true}`. The app restarts the talk in PCM at once; about one round trip of audio is lost.
   - Opus frames are never sent to a socket that cannot decode them. If an old build joins in the middle of an Opus talk, it is switched to PCM within the grace time.
   - The encoder failing (fails to open, or 10 empty frames in a row) also falls back to PCM, for the rest of the session.

### Receive path

The receive path is `lib/domain/audio/voice_jitter.dart`. Frames are decoded on arrival, then go through an adaptive jitter buffer and then into the existing playback queue (siren and Lead ducking, limiter and player feed are unchanged).

- **Target delay**: frame + 3 × RFC 3550 jitter, in whole 40 ms frames, clamped to **40-120 ms**. It rises at once and falls by one frame per 2 s.
- **Underrun**: the player finds nothing → re-buffer to a target one frame higher.
- **Loss** (a sequence gap, e.g. the relay dropped frames under backpressure): fade-repeat of the last frame, −6 dB per frame, at most 3 frames, then silence, with a 5 ms cross-fade back. A longer gap is skipped after one concealed frame, so it never adds its length to the delay.
- **Clock drift**: a playback queue more than 2 frames over the target for 1 s drops a frame. A slower sender underruns, which raises the target.
- **Hard cap**: 600 ms.

## 6. Mouth-to-ear latency budget (one hop, Opus, 4G)

| Stage | ms |
|---|---|
| AudioRecord buffer (record plugin) | 20-40 |
| Hub framing (20 ms frames) | 20 |
| Native cleanup (RNNoise + filters) | 12.5 |
| Dart post-stage (STFT) | 12 |
| Opus frame 20 + look-ahead 6.5 + second packet of the frame 20 | 46.5 |
| Platform-channel encode / decode hops | 3-5 |
| Uplink + downlink on 4G (TLS/TCP, no loss) | 60-160 |
| Relay | < 1 |
| Jitter buffer | 40-120 |
| Player feed (flutter_pcm_sound, about 60 ms threshold) | 40-60 |
| Output: speaker or wired 10-20, SCO 20-40, **A2DP 150-250** | 10-250 |
| **Total** | **about 270 ms best, 350-450 ms typical, up to about 650 ms with A2DP music headsets** |

PCM16 saves the 46.5 ms Opus framing but adds 40 ms framing and needs 8× the bytes. On a weak 4G link those bytes queue and cost far more than they save. Step 3 of the plan (an SFU with WebRTC over UDP) is the path to about 150-300 ms.

## 7. Gateway relay (`gateway/src/voice_relay.js`)

- **Lowest priority.** A voice frame goes to a socket only while that socket has no queued backlog (`ws.outq`) and at most `VOICE_DROP_BYTES` (16 KB) unsent. Otherwise the frame is dropped, never queued. That threshold is below `WS_OUT_SOFT_BYTES` (128 KB), where safety messages start to queue, so an SOS, alert or position is never behind more than 16 KB of audio. Before Round 8 voice could fill up to 512 KB ahead of them. The test `voice_relay_r8` "SOS overtakes voice" checks this.
- **Caps.** Per speaker: `VOICE_MAX_FPS` (100/s), `VOICE_MAX_BYTES_PER_SEC` (48 000), `VOICE_MAX_FRAME_BYTES` (16 384), and `VOICE_MAX_STREAM_MS` (60 s, existing).
- **Talk-time fairness.** After `VOICE_FAIR_HOLD_MS` (20 s) of holding the group floor, the next rider who presses talk takes it; the holder gets END with reason `fair-share`. The trip owner, Lead, sweeper and admins are exempt.
- **Metrics** (hub.stats, `coroute_ws_events_total{kind=...}` on /metrics):
  - `voiceBytesIn`, `voiceBytesOut`, `voiceFramesIn`, `voiceFramesOut`;
  - `voiceDropped` (backpressure), `voiceCapped`;
  - `voiceCodecRefused`, `voiceCodecSkipped`, `voiceFairShare`;
  - `voiceStreams`, and `voiceSpeakers` (live streams, a gauge).
- **`VOICE_RELAY_MODE=process`.** The gateway forks `src/voice_relay_server.js`, which listens on `VOICE_RELAY_HOST:VOICE_RELAY_PORT` (127.0.0.1:3010) at path `/voice`. Caddy routes `/voice` there (`deploy/caddy/voice_relay.caddy`).
  - Apps that sent VOICE_CAPS get a 10-minute HMAC ticket in `VOICE_CODEC.voice`. The ticket is keyed from `JWT_SECRET` and sent as the first message on /voice, never in a URL.
  - The app then opens `wss://host/voice` (`VoiceLink`) and talks and listens there.
  - The gateway stays the **authority** over IPC: it decides membership (attach / kick on leave), the floor, every START policy check (solo ride, admin switch, access mode, lead channel, codec) and MIC_STATUS.
  - Voice bytes of new apps reach the gateway only when an old build in the room still listens on /ws, or the two-node mirror needs them.
  - Old builds keep using /ws, and both sides hear each other.
  - If the voice process dies, it is restarted with a 1-30 s backoff. Its floors are freed and apps fall back to /ws by themselves.
  - Default `inprocess`: all voice on /ws, as before.

## 8. Licence and attribution (RNNoise)

The RNNoise source is BSD-3-Clause:

- © 2017 Mozilla
- © 2007-2017 Jean-Marc Valin
- © 2005-2017 Xiph.Org Foundation
- © 2003-2004 Mark Borgerding

The full text is in `android/app/src/main/cpp/rnnoise/COPYING`, and the licence header is kept in every source file. Provenance (crates.io `rnnoise-sys` 0.1.3, SHA-256 checked against the crates.io index, upstream sources unchanged) is in `rnnoise/README.vendor.md`.

The binary redistribution clause needs the notice in the app. Request to the lead: add the line above to the app's open-source licences screen and store listing.

There are no new pub dependencies: dart:ffi is part of the SDK. The tool-only Python packages used by the lab (numpy, scipy, pystoi) do not ship.

## 9. Limits (honest)

- **Not compiled for Android here.** The Kotlin (`VoiceCodecChannel.kt`), the Gradle `externalNativeBuild` and the NDK build have not been compiled for Android. The C code was compiled with host gcc and clang (no warnings at -Wall -Wextra) and with the same CMakeLists.txt on the host. One APK build is needed (QA A0).
- **Opus is verified as logic and wire format only.** The negotiation, packing, jitter, concealment and relay paths are tested. The MediaCodec encoder and decoder behaviour is not. Watch on devices: the CSD skip, output timing, the 48 kHz output.
- **No Opus FEC.** MediaCodec does not expose it. A fully verifiable future step is to vendor libopus (BSD-3) into the same native library: in-band FEC, DTX, real PLC and host tests.
- **Synthetic tests.** The speech is TTS and the noise is synthesised. Real helmet recordings will differ, in particular wind on a bare phone mic and very loud straight-pipe engines. RNNoise's model is trained on real speech and noise, which is in its favour.
- **Hands-free with siren detection on still uses the phone's mic** (3.55 trade-off). RNNoise helps most exactly there.
- **Traffic noise** (horns, passing trucks) is the least suppressed: it is non-stationary and sometimes tonal.
- **A2DP output** adds 150-250 ms. Nothing in the app can remove it.
