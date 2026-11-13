# Play Console build health plan (v3.57, build 3.55.0+10027)

Source: Play Console > App bundle explorer for the current release (pasted by the owner, 13 Nov 2026), checked
against the repo (`android/app/build.gradle.kts`, `proguard-rules.pro`, `AndroidManifest.xml`, `src/main/cpp`).

## Status (13 Nov 2026, source tree for build 3.55.0+10027)

Nothing below was compiled where it was changed (no Flutter/Android SDK there): every item still needs the first
release build and the checks in [ROUND9_BUILD_NOTES.md](ROUND9_BUILD_NOTES.md).

| Section | Status | Where |
|---|---|---|
| 1. Console reading | Done | this file |
| 2. Keep rules | **Done in source, not yet built.** Whole-package keeps replaced by library consumer rules + narrow rules; crash procedure at the top of `proguard-rules.pro`; `Log.v/d` stripped. Needs the release-build device test; plan order says ship in 10028 (see "Ship order" in R8_KEEP_RULES) | `android/app/proguard-rules.pro`, [R8_KEEP_RULES_v3.57.md](R8_KEEP_RULES_v3.57.md) |
| 3. Locales | **Done in source.** `androidResources.localeFilters` (AGP 9.0.1) = en, hi, te, ta, kn, ml, mr | `android/app/build.gradle.kts` |
| 4. Permissions | **Done in source.** `tools:node="remove"` for AD_ID, READ_PHONE_STATE, READ/WRITE_EXTERNAL_STORAGE, CAMERA (none used); c2dm RECEIVE and DYNAMIC_RECEIVER kept. Merged-manifest check pending (build) | `AndroidManifest.xml`, R8_KEEP_RULES section 3 |
| 5. Native / 16 KB | **Done in source, host-verified.** CMake builds arm64-v8a, armeabi-v7a, x86_64; flexible page sizes on; host build of the C sources: all LOAD p_align 0x4000; `tool/check_16kb_alignment.sh` added. Device test on a 16 KB image pending | `build.gradle.kts`, `src/main/cpp/CMakeLists.txt`, `tool/check_16kb_alignment.sh` |
| minSdk wording | **Done.** Effective minimum API 24; website/JSON-LD and docs say Android 7.0 or newer; gradle floor 24 (same result) | `gateway/public/*`, docs |
| 6. Declarations | **Texts ready**, owner to submit in the console | [PLAY_CONSOLE_DECLARATIONS_10027.md](PLAY_CONSOLE_DECLARATIONS_10027.md) |
| 7. Order / release checks | Release agent | [ROUND9_BUILD_NOTES.md](ROUND9_BUILD_NOTES.md) |

## 1. What the console shows, and what it means

| Item | Console | Verdict |
|---|---|---|
| Supported devices | 19,538 | Good. Telephony is `required="false"`, so tablets without a SIM install too |
| API levels | 24+ | Flutter's minimum is 24 (the gradle floor was `maxOf(flutter.minSdkVersion, 23)`, now `..., 24`; same result). Docs and website now say Android 7.0 or newer; Kotlin guards for API 23 are harmless |
| Target SDK | 36 | Good: meets Play's API 36 rule for updates from 31 Aug 2026 |
| Native platforms | arm64-v8a, armeabi-v7a, x86_64 | Fine. The new voice library must be built for all three (section 5) |
| Memory page size | Supports 16 KB | Good for this release. **Round 8 adds a native library** (`libcoroute_voice.so`): it is linked with `-z max-page-size=16384` and NDK 28, but must be verified (section 5) |
| Screen layouts | small to xlarge | Fine |
| OpenGL | 0.0+, no textures | Fine |
| Localizations | **85** | The app itself has 3 (English, Hindi, Telugu); the other 82 come from libraries (AndroidX, Play services). Trim (section 3) |
| Permissions | **23** | 21 in our manifest; 2 added by libraries. Audit (section 4) |
| DEX optimization | **Medium: 46 % optimized, 47 % obfuscated, 47 % shrunk**, 3.15 MB | Broad keep rules stop R8 from doing its job. Fix (section 2) |
| R8 | Full mode, resource shrinking (optimized), repackage classes | Good settings; the keep rules are the problem |

## 2. Code optimization: from 46 % to a higher score, safely

**Cause:** `proguard-rules.pro` keeps whole packages, every class and every member, so R8 can neither shrink,
rename nor optimize them:

| Rule | Why it is too broad | Replace with |
|---|---|---|
| `-keep class space.devmonks.coroute_app.** { *; }` | keeps all our Kotlin (17+ channels and services) | nothing for classes referenced from the manifest (R8 keeps activities, services, receivers, tile service automatically); keep only what is called by reflection or JNI by name. dart:ffi calls the C library directly, so no JNI keep is needed for voice |
| `-keep class io.flutter.** { *; }` | Flutter ships its own consumer rules | remove; rely on the embedding's consumer rules |
| `-keep class com.dexterous.** { *; }` | flutter_local_notifications needs only its gson-serialized model classes | the plugin's documented rules (its models + gson `TypeToken` rules) |
| `-keep class com.google.gson.** { *; }` | gson itself does not need keeping | keep `TypeToken` subclasses and fields of serialized classes only (`-keep class * extends com.google.gson.reflect.TypeToken`, `-keepclassmembers` with `@SerializedName`) |
| `-keep class com.pravera.flutter_foreground_task.** { *; }`, `com.llfbandit.record.**`, `androidx.credentials.playservices.**`, `com.google.android.gms.auth.**` | whole-package keeps | the plugins' own consumer rules if present; otherwise narrow to the service / receiver classes they start by name |

**Steps:**
1. Build release once with the current rules and save `build/app/outputs/mapping/release/usage.txt`,
   `configuration.txt` and the APK size (baseline).
2. Replace the broad rules (table above) in one branch. Add `-printconfiguration` and `-whyareyoukeeping` checks
   for the classes that still stay.
3. Release build, then run the full device check: notifications (ride, SOS, crash full-screen alarm, actions from
   the lock screen), foreground service start/stop, microphone recording + intercom, Google sign-in, quick settings
   tile, boot receiver, emergency texts queue, lock-screen cockpit, app lock, live update (Android 16).
   Any crash: read the stack trace with the mapping file and add the narrowest keep for that class.
4. Upload to internal testing; compare the console's DEX score and size with the baseline.

Expected: optimization/obfuscation/shrinking well above 46 % and a smaller DEX. A crash here would show only on a
release build, so step 3 is a release-build test, never a debug test.

**Do not** turn off minify or obfuscation to make warnings go away.

## 3. Localizations: from 85 to the languages we support

Add to `android { defaultConfig { ... } }`:

```kotlin
androidResources {
    localeFilters += listOf("en", "hi", "te", "ta", "kn", "ml", "mr")
}
```

(`localeFilters` on AGP 8.7+; on older AGP use `resourceConfigurations += listOf(...)`.) This keeps English, the two
languages the app speaks today and the four planned in the v3.56 plan (Tamil, Kannada, Malayalam, Marathi), and drops
library strings for 78 other locales. Effect: smaller resources, and the store no longer lists 85 languages the app
does not offer. System dialogs from libraries (for example Google sign-in) show in English in a dropped locale.
Add a language here before it is offered in Settings > Language.

## 4. Permissions: 23 in the bundle

Ours (21) and what each needs on Play:

| Permission | Used for | Play requirement |
|---|---|---|
| ACCESS_FINE / COARSE_LOCATION | rides, SOS position | Data safety: location |
| **ACCESS_BACKGROUND_LOCATION** | ride tracking and crash/SOS with the screen off | **Location permissions declaration + video** (already part of the Play checklist) |
| FOREGROUND_SERVICE, **_LOCATION**, **_MICROPHONE** | ride service; intercom while riding | **Foreground service types declaration** (App content) with a short video for each type |
| RECORD_AUDIO, MODIFY_AUDIO_SETTINGS, BLUETOOTH_CONNECT | intercom, siren detection, helmet headset | Data safety: audio (processed on the phone / relayed live, not stored) |
| **SEND_SMS** | emergency texts from the rider's own SIM | **SMS declaration** (submitted in round 2) |
| **USE_FULL_SCREEN_INTENT** | crash alarm over the lock screen | Android 14+: Play only grants it to calling/alarm apps; **declare it** (App content > Full-screen intent) as an alarm for crash detection, otherwise the alarm falls back to a heads-up notification on new installs |
| **REQUEST_IGNORE_BATTERY_OPTIMIZATIONS** | keep crash detection and SOS alive on aggressive phones | restricted: allowed for safety apps whose core function needs it; justify in the review notes |
| ACCESS_NOTIFICATION_POLICY | crash alarm sound through Do Not Disturb | normal; explained in the app |
| POST_NOTIFICATIONS, POST_PROMOTED_NOTIFICATIONS (Android 16 live update), VIBRATE, WAKE_LOCK, RECEIVE_BOOT_COMPLETED, INTERNET, ACCESS_NETWORK_STATE, USE_BIOMETRIC, BIND_QUICK_SETTINGS_TILE | normal | none |

The 2 extra ones come from libraries (likely Firebase messaging's `c2dm RECEIVE` and AndroidX's
`DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION`, both harmless). **Check** with the merged manifest
(`build/app/intermediates/merged_manifests/release/AndroidManifest.xml`) and remove any library permission we do not
use with `<uses-permission android:name="..." tools:node="remove"/>`, especially READ_PHONE_STATE, READ_EXTERNAL_STORAGE,
CAMERA or AD_ID if a library added them (our app uses none of these; the profile photo picker uses the system picker).
Data safety must match the final list.

## 5. Native code and 16 KB pages (new in round 8)

1. CMake builds `libcoroute_voice.so` for **arm64-v8a, armeabi-v7a and x86_64** (the bundle's ABIs). Without the
   x86_64 build, Chromebooks and emulators fall back to the old voice cleanup (safe, but worse).
2. Verify 16 KB alignment of every native library in the release bundle:
   `zipalign -c -P 16 -v 4 app-release.apk` and Android's `check_elf_alignment.sh` (from the page-size guide), or the
   console's "Memory page size" line after upload. Expected: still "Supports 16 KB".
3. Test on a 16 KB device or emulator image (Android 15+ "16 KB page size" system image): intercom with noise
   reduction Strong must work.
4. `useLegacyPackaging = true` stores native libraries compressed. (Correction, v3.57 review: AGP also passes it to
   the bundle config, so Play's APKs may carry compressed libraries too.) Fine either way: compressed libraries are
   extracted at install, and only ELF alignment matters for them; the console reported "Supports 16 KB" with it.

## 6. Console declarations to check for release 10027

- Data safety: device IDs (hashed Android id + install id, security; round 3), approximate location / app activity
  for road safety with consent (round 4), audio (intercom, not stored), photos (profile picture, already declared).
- Foreground service types (location, microphone), background location, SMS, full-screen intent (section 4).
- Open-source notice: RNNoise (BSD-3) is listed in the app (Privacy & terms > Open-source licences).

## 7. Order

1. Section 4 merged-manifest check and section 3 locale filter (low risk) in build 10027.
2. Section 5 native checks in build 10027 (required: round 8 adds the native library).
3. Section 2 keep-rule tightening in its own build (10028) after 10027 is stable, with the full release-build device
   check, because it is the change most likely to cause a release-only crash.
4. Section 6 declarations before promoting 10027 beyond internal testing.
