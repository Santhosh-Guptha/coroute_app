# Round 9 build notes: build health checks for the release agent (3.55.0+10027)

What changed and why: [R8_KEEP_RULES_v3.57.md](R8_KEEP_RULES_v3.57.md). Plan and status:
[PLAY_BUILD_HEALTH_PLAN_v3.57.md](PLAY_BUILD_HEALTH_PLAN_v3.57.md). Console forms:
[PLAY_CONSOLE_DECLARATIONS_10027.md](PLAY_CONSOLE_DECLARATIONS_10027.md).

None of the Android changes were compiled where they were written (no Flutter/Android SDK there). The first build is
the first check: if Gradle fails on `androidResources.localeFilters` or `externalNativeBuild.cmake.abiFilters`, read
the error, fix it in `android/app/build.gradle.kts`, and do not remove the feature.

## Build

```bash
flutter clean && flutter pub get
# Baseline for comparison (optional, plan section 2 step 1): build once from the previous tag and keep
# build/app/outputs/mapping/release/{usage,configuration}.txt and the .aab size.
flutter build appbundle --release            # Play upload: build/app/outputs/bundle/release/app-release.aab
flutter build apk --release --split-per-abi  # side-load APKs (optional)
```

Keep `build/app/outputs/mapping/release/mapping.txt` (and the whole `mapping/release/` folder) next to the .aab in
the release archive: it is the only way to read a release stack trace later.

## Checks before upload

1. **16 KB / native libraries**
   ```bash
   tool/check_16kb_alignment.sh build/app/outputs/bundle/release/app-release.aab
   tool/check_16kb_alignment.sh build/app/outputs/flutter-apk/app-*-release.apk   # if APKs were built
   ```
   Expect `PASS`, `libcoroute_voice.so` present for arm64-v8a, armeabi-v7a and x86_64 (no `WARN` line), and `OK`
   for zipalign when `ANDROID_HOME` is set. For the exact APKs Play will serve:
   `bundletool build-apks --bundle app-release.aab --output out.apks --mode=universal` (then unzip and run the
   script on `universal.apk`).
2. **Merged manifest review** (permissions and components after all libraries):
   ```bash
   cat build/app/intermediates/merged_manifests/release/processReleaseManifest/AndroidManifest.xml \
     | grep -o 'uses-permission[^>]*android:name="[^"]*"' | sort
   # (the folder name varies by AGP version; find it with:
   #   find build/app/intermediates -path '*release*' -name AndroidManifest.xml | grep -i merged)
   # or from the bundle itself:
   bundletool dump manifest --bundle build/app/outputs/bundle/release/app-release.aab | grep uses-permission
   ```
   Expect our 21 plus `com.google.android.c2dm.permission.RECEIVE` and
   `space.devmonks.coroute_app.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`; **not** `AD_ID`, `READ_PHONE_STATE`,
   `READ/WRITE_EXTERNAL_STORAGE`, `CAMERA`. Anything else new: decide (keep + declare, or `tools:node="remove"`)
   and update the Data safety form. The full merger log is
   `build/app/outputs/logs/manifest-merger-release-report.txt` (shows which library added what).
3. **R8 output**: `build/app/outputs/mapping/release/configuration.txt` must not contain
   `-keep class space.devmonks.coroute_app.** { *; }` or `-keep class io.flutter.** { *; }` from our file; skim
   `usage.txt` size against the baseline.
4. **Release-build device test**: the 14 items in [R8_KEEP_RULES_v3.57.md section 5](R8_KEEP_RULES_v3.57.md#5-release-build-device-test-list-run-on-a-release-build-never-debug)
   on a release build (internal testing install). Plus intercom with noise reduction Strong on a 16 KB device or the
   Android 15+ "16 KB page size" emulator image. If the keep-rule change cannot be tested before 10027 ships, follow
   the "Ship order" note at the top of R8_KEEP_RULES_v3.57.md.
5. `dart tool/play_policy_scan.dart` -> 0 hits.

## Upload

- Upload the .aab to **internal testing**.
- **Deobfuscation file**: `flutter build appbundle` puts `mapping.txt` inside the .aab (BUNDLE-METADATA) and Play
  picks it up; confirm in App bundle explorer > the build > Downloads that "ReTrace mapping file" is present. If not,
  upload `build/app/outputs/mapping/release/mapping.txt` there.
- **Native debug symbols**: `debugSymbolLevel = "SYMBOL_TABLE"` puts them in the .aab; confirm "Native debug symbols"
  is listed. If the console warns they are missing, upload the zip of
  `build/app/intermediates/merged_native_libs/release/mergeReleaseNativeLibs/out/lib` (unstripped) or
  `build/app/outputs/native-debug-symbols/release/native-debug-symbols.zip` when present.
- Flutter's Dart code is AOT in `libapp.so`; for Dart stack traces build with
  `--obfuscate --split-debug-info=build/symbols` only if the team already uses it (not changed in this round).

## What to read in the console after upload (App bundle explorer > the new build > Details)

| Line | Before (10026 report) | Expect |
|---|---|---|
| DEX optimization | Medium: 46 % optimized, 47 % obfuscated, 47 % shrunk, 3.15 MB | clearly higher percentages and a smaller DEX (if the keep-rule change ships) |
| Localizations | 85 | about 7 (en, hi, te, ta, kn, ml, mr), possibly a few more from region variants |
| Permissions | 23 | 23 (or fewer if a library had added one of the removed ones); list must match the Data safety form |
| Memory page size | Supports 16 KB | still "Supports 16 KB" |
| Native platforms | arm64-v8a, armeabi-v7a, x86_64 | unchanged |
| API levels | 24+ | 24+ (public texts now say Android 7.0 or newer) |
| Supported devices | 19,538 | about the same |

If "Memory page size" no longer says 16 KB: run the script on the downloaded universal APK, find the library, do
not promote the build.
