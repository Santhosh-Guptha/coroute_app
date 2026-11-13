#!/usr/bin/env bash
# CoRoute: check 16 KB page-size support of every native library in a built APK or AAB.
#
#   tool/check_16kb_alignment.sh build/app/outputs/bundle/release/app-release.aab
#   tool/check_16kb_alignment.sh build/app/outputs/flutter-apk/app-arm64-v8a-release.apk [more files...]
#   tool/check_16kb_alignment.sh some/dir/with/libs        (checks every .so below it)
#
# For every lib/<abi>/*.so (APK) or base/lib/<abi>/*.so (AAB) it reads the ELF program headers and
# requires every PT_LOAD segment to be aligned to at least 16 KB (p_align >= 0x4000), the same rule as
# Android's check_elf_alignment.sh (developer.android.com/guide/practices/page-sizes). 64-bit ABIs
# (arm64-v8a, x86_64) must pass; 32-bit ABIs (armeabi-v7a, x86) are reported but never fail, because
# 16 KB devices are 64-bit only.
# For an APK it also runs `zipalign -c -P 16 -v 4` when zipalign is found (PATH, $ANDROID_HOME or
# $ANDROID_SDK_ROOT build-tools): uncompressed .so files must start on a 16 KB boundary in the zip.
# CoRoute stores native libraries compressed (useLegacyPackaging = true), which is fine: they are
# extracted at install, so only the ELF check applies to them. For an AAB, Play builds the APKs; zipalign does not apply.
#
# Needs: unzip, and readelf / llvm-readelf (binutils, or the NDK's toolchains/llvm/prebuilt/*/bin).
# Exit status: 0 = all 64-bit libraries are 16 KB aligned, 1 = at least one is not, 2 = usage/tool error.
# Release procedure: docs/release/ROUND9_BUILD_NOTES.md.

set -u

if [ "$#" -lt 1 ]; then
  sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

# --- find readelf ------------------------------------------------------------------------------
READELF=""
for c in llvm-readelf readelf; do
  if command -v "$c" >/dev/null 2>&1; then READELF="$c"; break; fi
done
if [ -z "$READELF" ]; then
  for root in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}" "${ANDROID_HOME:-}/ndk/"* "${ANDROID_SDK_ROOT:-}/ndk/"*; do
    [ -n "$root" ] || continue
    for f in "$root"/toolchains/llvm/prebuilt/*/bin/llvm-readelf; do
      if [ -x "$f" ]; then READELF="$f"; break 2; fi
    done
  done
fi
if [ -z "$READELF" ]; then
  echo "ERROR: readelf or llvm-readelf not found (install binutils or set ANDROID_NDK_HOME)." >&2
  exit 2
fi

# --- find zipalign (optional) ------------------------------------------------------------------
ZIPALIGN=""
if command -v zipalign >/dev/null 2>&1; then
  ZIPALIGN="zipalign"
else
  for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}"; do
    [ -n "$sdk" ] || continue
    # newest build-tools last in glob order
    for f in "$sdk"/build-tools/*/zipalign; do
      [ -x "$f" ] && ZIPALIGN="$f"
    done
  done
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/coroute16k.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT

fail=0
checked=0

# check_so <file> <label>
check_so() {
  local so="$1" label="$2" abi bad aligns
  abi="$(basename "$(dirname "$so")")"
  if ! "$READELF" -h "$so" >/dev/null 2>&1; then
    echo "  SKIP  $label (not an ELF file)"
    return
  fi
  checked=$((checked + 1))
  # Last field of each LOAD line in `readelf -lW` is the alignment, e.g. 0x4000.
  aligns="$("$READELF" -lW "$so" 2>/dev/null | awk '$1 == "LOAD" { print $NF }')"
  if [ -z "$aligns" ]; then
    echo "  FAIL  $label (no LOAD segments found)"
    fail=1
    return
  fi
  bad=""
  for a in $aligns; do
    # 2**14 = 16384. Accept larger powers of two too (e.g. 0x10000).
    if [ $((a)) -lt 16384 ]; then bad="$bad $a"; fi
  done
  local shown
  shown="$(echo $aligns | tr ' ' ',')"
  if [ -z "$bad" ]; then
    echo "  OK    $label  (LOAD p_align: $shown)"
  else
    case "$abi" in
      armeabi-v7a|armeabi|x86|mips)
        echo "  INFO  $label  (32-bit, LOAD p_align: $shown; 16 KB not required)" ;;
      *)
        echo "  FAIL  $label  (LOAD p_align: $shown; needs >= 0x4000)"
        fail=1 ;;
    esac
  fi
}

for input in "$@"; do
  if [ -d "$input" ]; then
    echo "== $input (directory)"
    found=0
    while IFS= read -r -d '' so; do
      found=1
      check_so "$so" "${so#"$input"/}"
    done < <(find "$input" -type f -name '*.so' -print0 | sort -z)
    [ "$found" = 1 ] || echo "  (no .so files)"
    continue
  fi
  if [ ! -f "$input" ]; then
    echo "ERROR: $input not found" >&2
    fail=1
    continue
  fi
  echo "== $input"
  dest="$WORK/$(basename "$input").d"
  mkdir -p "$dest"
  if ! unzip -qq -o "$input" 'lib/*.so' 'base/lib/*.so' -d "$dest" 2>/dev/null; then
    # unzip returns 11 when one of the two patterns has no match; that is fine.
    :
  fi
  found=0
  while IFS= read -r -d '' so; do
    found=1
    check_so "$so" "${so#"$dest"/}"
  done < <(find "$dest" -type f -name '*.so' -print0 | sort -z)
  [ "$found" = 1 ] || echo "  (no native libraries in this file)"

  # Expect the voice library for every shipped ABI (round 8).
  for abi in arm64-v8a armeabi-v7a x86_64; do
    for libdir in "$dest/lib/$abi" "$dest/base/lib/$abi"; do
      if [ -d "$libdir" ] && [ ! -f "$libdir/libcoroute_voice.so" ]; then
        echo "  WARN  $abi has native libraries but no libcoroute_voice.so (voice cleanup falls back to Dart)"
      fi
    done
  done

  case "$input" in
    *.apk)
      if [ -n "$ZIPALIGN" ]; then
        if "$ZIPALIGN" -c -P 16 -v 4 "$input" >"$WORK/zipalign.log" 2>&1; then
          echo "  OK    zipalign -c -P 16 -v 4"
        else
          echo "  FAIL  zipalign -c -P 16 -v 4 (see lines marked BAD):"
          grep -i "bad\|fail" "$WORK/zipalign.log" | head -20 | sed 's/^/        /'
          fail=1
        fi
      else
        echo "  NOTE  zipalign not found (set ANDROID_HOME); zip alignment not checked"
      fi
      ;;
  esac
done

echo
if [ "$checked" = 0 ]; then
  echo "No native libraries were checked."
  exit 2
fi
if [ "$fail" = 0 ]; then
  echo "PASS: every 64-bit native library is 16 KB aligned ($checked checked, readelf: $READELF)."
  exit 0
fi
echo "FAIL: see the lines marked FAIL above."
exit 1
