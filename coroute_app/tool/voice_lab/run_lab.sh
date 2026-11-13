#!/bin/bash
# Round 8 voice lab: builds the native voice cleanup for the host, generates synthetic riding audio,
# runs every variant and scores it. Usage (from the repository root):
#   tool/voice_lab/run_lab.sh [WORKDIR]
# Writes tool/voice_lab/results.json (and prints the table). Needs gcc, python3 + numpy + scipy,
# ffmpeg with flite (falls back to formant-synth speech), and dart for the 3.55 Dart chain.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${1:-$(mktemp -d)}"
DART="${DART:-/opt/dartpkg/bin/dart}"
C="$ROOT/android/app/src/main/cpp"
mkdir -p "$WORK/proc"
gcc -O2 -std=gnu99 -Wall -Wextra -Wno-unused-parameter -Wno-unused-variable -Wno-unused-function -Wno-sign-compare \
  -I"$C" -I"$C/rnnoise/include" -I"$C/rnnoise/src" "$ROOT/tool/voice_lab/cv_cli.c" "$C/coroute_voice.c" \
  "$C"/rnnoise/src/{denoise,rnn,rnn_data,pitch,kiss_fft,celt_lpc}.c -lm -o "$WORK/cv_cli"
gcc -O2 -std=gnu99 -shared -fPIC -fvisibility=hidden -I"$C" -I"$C/rnnoise/include" -I"$C/rnnoise/src" "$C/coroute_voice.c" \
  "$C"/rnnoise/src/{denoise,rnn,rnn_data,pitch,kiss_fft,celt_lpc}.c -lm -o "$WORK/libcoroute_voice.so"
python3 "$ROOT/tool/voice_lab/voice_lab.py" gen "$WORK"
# Run the Dart CLI from outside the package (no pub resolution, like tool/pure_dart_test).
cp "$ROOT/tool/voice_lab/dart_cleanup_cli.dart" "$WORK/dart_cleanup_cli.dart"
files=(clean $(python3 -c "import json,sys; print(' '.join(json.load(open(sys.argv[1]))['mixes']))" "$WORK/meta.json"))
run_c() { # variant mode wind
  mkdir -p "$WORK/proc/$1"
  for f in "${files[@]}"; do "$WORK/cv_cli" "$2" "$3" "$WORK/$f.wav" "$WORK/proc/$1/$f.wav" > "$WORK/proc/$1/$f.json"; done
  cp "$WORK/proc/$1/clean.json" "$WORK/proc/$1/info.json"
}
run_dart() { # variant spectral gate agc [input variant]
  mkdir -p "$WORK/proc/$1"
  for f in "${files[@]}"; do
    src="$WORK/$f.wav"; [ -n "${5:-}" ] && src="$WORK/proc/$5/$f.wav"
    (cd "$WORK" && "$DART" run --packages="$ROOT/.dart_tool/package_config.json" "$WORK/dart_cleanup_cli.dart" "$2" "$3" "$4" "$src" "$WORK/proc/$1/$f.wav") > "$WORK/proc/$1/$f.json"
  done
  cp "$WORK/proc/$1/clean.json" "$WORK/proc/$1/info.json"
}
run_c a_off 0 0
run_dart b_dart355_normal 1 0 0
run_c c_rnnoise_normal 1 1
run_c d_rnnoise_strong 2 1
run_c e_strong_nowind 2 0
# Strong as shipped: RNNoise + the Dart post-stage (breath / wind classes, no Wiener); gate + AGC off to measure.
run_dart f_strong_plus_dart_post 0 0 0 d_rnnoise_strong
# The post-stage adds 192 samples on top of the native 200.
python3 - "$WORK/proc/f_strong_plus_dart_post/info.json" <<'PY'
import json,sys; p=sys.argv[1]; d=json.load(open(p)); d['latency16k']=392; json.dump(d,open(p,'w'))
PY
# The app's dart:ffi binding against the same C build: must be sample-identical to the C harness.
cp "$ROOT/tool/voice_lab/ffi_check.dart" "$WORK/ffi_check.dart"
(cd "$WORK" && "$DART" run --packages="$ROOT/.dart_tool/package_config.json" "$WORK/ffi_check.dart" "$WORK/libcoroute_voice.so" \
  "$WORK/highway_mix_0dB.wav" "$WORK/proc/d_rnnoise_strong/highway_mix_0dB.wav") | tee "$WORK/ffi_check.json"
# CPU on a quiet core: the strong chain over the whole highway mix, 3 runs, best one.
for i in 1 2 3; do "$WORK/cv_cli" 2 1 "$WORK/highway_mix_0dB.wav" "$WORK/cpu.wav"; done | sort -t: -k3 -n | head -1 > "$WORK/cpu.json"
cat "$WORK/cpu.json"
python3 "$ROOT/tool/voice_lab/voice_lab.py" score "$WORK" "$ROOT/tool/voice_lab/results.json"
