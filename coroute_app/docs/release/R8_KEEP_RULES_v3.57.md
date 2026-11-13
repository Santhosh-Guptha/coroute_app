# R8 keep rules, locales, permissions and native build (v3.57 build health)

Build 3.55.0+10027 source tree. Plan: [PLAY_BUILD_HEALTH_PLAN_v3.57.md](PLAY_BUILD_HEALTH_PLAN_v3.57.md).
Files changed: `android/app/proguard-rules.pro`, `android/app/build.gradle.kts`,
`android/app/src/main/AndroidManifest.xml`, `android/app/src/main/cpp/CMakeLists.txt`,
`tool/check_16kb_alignment.sh` (new).

Nothing here was built: this machine has no Flutter, Android SDK or Gradle. Everything below must be confirmed with a
release build and the device test list (end of this file). The keep-rule change is the one most likely to cause a
crash that only shows in a release build.

> **Ship order (plan section 7).** The plan puts the keep-rule tightening in its own build (10028), after 10027 is
> stable. The new `proguard-rules.pro` is in the tree now because the owner asked for every section. If 10027 must
> ship before the release-build device test below has been run, put the previous rules back for that build only
> (they are listed in the table, column "Before"), and bring the new file back for 10028.

## 1. Keep rules (`proguard-rules.pro`)

How the facts were checked: the plugin versions come from `.dart_tool/package_config.json`; the Android sources of
the plugins are not in the offline pub cache (`/opt/deps`, Dart only), so each plugin's Gradle file and docs were
read from its GitHub repository (links below). Our Kotlin was searched for `Class.forName`, `getMethod`,
`getDeclared*`, `newInstance`, Gson, `Serializable`/`Parcelable`, `getIdentifier`, `System.loadLibrary`.

| Before | After | Why |
|---|---|---|
| `-keep class space.devmonks.coroute_app.** { *; }` | removed | Nothing of ours is reached by name. Manifest components (MainActivity, ShareInActivity, RideSosActivity, UrgentAlertActivity, MedicalIdActivity, MedicalTileService, EmergencyTextReceiver, CoRouteMessagingService) are kept by AGP's generated manifest rules. Platform channels are objects registered in code. No JNI: `libcoroute_voice.so` is called from Dart with dart:ffi by C symbol (`cv_*`), never from Java. Kotlin uses `org.json` (framework), no Gson. The only reflection is in `RideNotification.kt` (Android 16 Live Update: `Notification.Builder.setShortCriticalText`, `Notification$ProgressStyle`, `NotificationManager.canPostPromotedNotifications`) and it targets framework classes, which R8 never renames or removes |
| `-keep class io.flutter.** { *; }` | removed | flutter_tools adds `flutter_proguard_rules.pro` to every release build (keeps each `FlutterPlugin` implementation, `-dontwarn android.**`) — https://github.com/flutter/flutter/blob/master/packages/flutter_tools/gradle/flutter_proguard_rules.pro ; the engine's JNI callbacks in the embedding are annotated `@Keep`. A new Flutter app has no io.flutter rule at all |
| `-keep class com.dexterous.** { *; }` | removed | flutter_local_notifications 19.5.0: "For flutter_local_notifications v19 and higher, the ProGuard rules are automatically provided by the GSON" (README, "ProGuard rules") — https://github.com/MaikuB/flutter_local_notifications/blob/master/flutter_local_notifications/README.md ; its model classes are annotated `@Keep` (`models/NotificationDetails.java` imports `androidx.annotation.Keep`); CHANGELOG: "bumped GSON dependency to 2.12 ... applications should no longer need ProGuard rules related to this plugin". Its receivers are in our manifest (kept) |
| `-keep class com.google.gson.** { *; }` | removed | Gson 2.12 (pulled by the plugin) ships its own R8 rules in the jar (`TypeToken`, `@SerializedName` fields) |
| `-keepattributes Signature, *Annotation*` | `-keepattributes Signature` | Signature stays as cheap insurance for the plugin's generic Gson reads (scheduled plan-expiry reminders). `*Annotation*`: `@Keep` is read by R8 at build time and Gson's bundled rules keep what Gson needs at run time; attributes do not change the DEX score much either way |
| `-keep class com.pravera.flutter_foreground_task.** { *; }` | removed | flutter_foreground_task 11.0.3 ships no consumer rules and needs none: no reflection (checked `FlutterForegroundTaskPlugin.kt`, `service/ForegroundService.kt`, `service/ForegroundTask.kt`, `service/ForegroundServiceManager.kt`, `models/ForegroundTaskOptions.kt`: options are stored with `org.json`, the Dart entry point is found with `FlutterCallbackInformation`). `ForegroundService` is declared in our manifest; `RebootReceiver`/`RestartReceiver` in the plugin's manifest — https://github.com/Dev-hwang/flutter_foreground_task/blob/master/android/src/main/AndroidManifest.xml . Enum `values()/valueOf()` are kept by `proguard-android-optimize.txt` |
| `-keep class com.llfbandit.record.** { *; }` | removed | record_android 2.2.0 ships no consumer rules (`record_android/android/build.gradle.kts` has none) and uses framework audio APIs directly — https://github.com/llfbandit/record/blob/master/record_android/android/build.gradle.kts |
| `-keep class com.google.android.gms.auth.** { *; }` | removed | google_sign_in_android 6.2.1 uses Play services auth, whose AARs ship their own consumer rules |
| `-keep class androidx.credentials.playservices.** { *; }` | `-if class androidx.credentials.CredentialManager` + the same keep | The rule from the Credential Manager integration guide (developer.android.com/identity/sign-in/credential-manager, ProGuard note; the page could not be fetched from this machine, rule quoted from that guide). The `-if` makes it a no-op while Credential Manager is not on the classpath (google_sign_in 6.x) and correct once google_sign_in 7 brings it |
| (none) | `-assumenosideeffects class android.util.Log { v(...); d(...) }` | Drops verbose/debug logcat calls (library chatter). Allowed because the diagnostics log (`lib/domain/diag/diag_log.dart`, `DiagLogService`) is pure Dart writing files and never uses `android.util.Log`; our Kotlin uses only `Log.i` (TtsChannel diagnostic lines) and `Log.w` (EmergencyTexts, CrashLog, VoiceCodecChannel), which stay. Methods are named exactly, never `{ *; }` |
| `-dontwarn ...` lines | unchanged | warnings only; they keep nothing |

The "if a release build crashes" procedure (mapping file, `retrace`, `-whyareyoukeeping`, `-printusage`) is at the
top of `proguard-rules.pro`.

Known side effect: `CrashLog.kt` writes `error.javaClass.name` into the local crash log. Exception classes of the
framework keep their names; any of our or library classes now show obfuscated names there. De-obfuscate with the
build's `mapping.txt` (and Play does it for Android vitals once the mapping is uploaded).

Libraries never kept by our file before (path_provider/jni, geolocator, permission_handler, image_picker, sqflite,
url_launcher, share_plus, shared_preferences, Firebase Messaging, Play In-App Review) are unchanged: they already ran
on their own consumer rules in the previous release.

## 2. Locales (`build.gradle.kts`)

`android { androidResources { localeFilters += listOf("en","hi","te","ta","kn","ml","mr") } }`. AGP is 9.0.1
(`android/settings.gradle.kts`), so `localeFilters` (AGP 8.7+) is used, not the deprecated `resourceConfigurations`.
The app's own UI text is Dart (not affected). Library dialogs fall back to English in other locales. Add a language
here before offering it in Settings > Language.

## 3. Permissions (`AndroidManifest.xml`)

`xmlns:tools` added to `<manifest>`. The bundle shows 23 permissions: our 21 plus, by the plan's estimate, Firebase's
`com.google.android.c2dm.permission.RECEIVE` (needed for FCM) and AndroidX's
`space.devmonks.coroute_app.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` (needed by AndroidX for receivers). Both stay.
`tools:node="remove"` was added for permissions CoRoute certainly does not use and that libraries commonly add (a
no-op when no library adds them, so the count may stay 23):

| Permission | Decision | Reason |
|---|---|---|
| `com.google.android.gms.permission.AD_ID` | remove | No ads. Firebase is Messaging only (`firebase-messaging` from the BoM, no Analytics; `build.gradle.kts`), so nothing reads the advertising ID. Play Console > App content > Advertising ID: "No" |
| `READ_PHONE_STATE` | remove | Never requested (no `Permission.phone` in Dart). `PhoneCallChannel.kt` detects calls from the audio mode and only uses the telephony state if the permission "happens to be granted" (checked with `checkSelfPermission`); emergency texts use the default SMS SIM without listing SIMs. No feature changes |
| `READ_EXTERNAL_STORAGE`, `WRITE_EXTERNAL_STORAGE` | remove (no `maxSdkVersion` exception needed) | Nothing reads or writes shared storage: photos come from the system photo picker (image_picker), the diagnostics bundle is written to the app cache and shared with `share_plus` (`DiagLogService.shareFile`), all other files are app-private |
| `CAMERA` | remove | "Take a new photo" (profile, trip feedback, place review) is `ImagePicker().pickImage(source: ImageSource.camera)`, which image_picker_android implements with the camera app (`ACTION_IMAGE_CAPTURE`, declared in `<queries>`): no permission. If CAMERA were declared, Android would refuse `ACTION_IMAGE_CAPTURE` until it is granted, so removing a library-added CAMERA protects the feature |

After the first build, read the merged manifest (command in [ROUND9_BUILD_NOTES.md](ROUND9_BUILD_NOTES.md)) and make
sure the list matches the Data safety form ([PLAY_CONSOLE_DECLARATIONS_10027.md](PLAY_CONSOLE_DECLARATIONS_10027.md)).

## 4. Native library and 16 KB pages

- `build.gradle.kts` `defaultConfig.externalNativeBuild.cmake.abiFilters = arm64-v8a, armeabi-v7a, x86_64`: CMake
  compiles `libcoroute_voice.so` for all three bundle ABIs. This is not `ndk.abiFilters`, so it does not clash with
  `--split-per-abi` (AGP refuses `ndk.abiFilters` together with ABI splits) or Flutter's `--target-platform`.
- `arguments += -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON` (default in NDK r28 = the project's 28.2.13676358; explicit
  so another NDK cannot produce a 4 KB-only library). `-Wl,-z,max-page-size=16384` stays in `CMakeLists.txt`.
- `-Wl,-z,common-page-size=16384` **not added**. Host check with the same sources and flags (clang 18 + lld,
  x86_64): with `max-page-size=16384` every `LOAD` segment has `p_align 0x4000`; adding `common-page-size` leaves
  `p_align` unchanged and only grows the RELRO `MemSiz` from 0x7e0 to 0x27e0 (padding). GNU ld gives 0x4000 too.
- Exported dynamic symbols: the `cv_*` API plus RNNoise's own `rnnoise_*` functions (RNNoise marks them public with
  `RNNOISE_BUILD`). Harmless; noted for completeness.
- `tool/check_16kb_alignment.sh <apk|aab|dir>...`: checks `p_align >= 0x4000` for every `.so` (64-bit ABIs must pass,
  32-bit reported only), warns when an ABI lacks `libcoroute_voice.so`, runs `zipalign -c -P 16 -v 4` on APKs when
  zipalign is found. Tested here on synthetic APK/AAB files (pass, 4 KB fail, usage exit codes).

## 5. Release-build device test list (run on a RELEASE build, never debug)

Install the Play internal-testing build (or `flutter build apk --release` signed with the upload key). For each item:
works on the lock screen where it applies, nothing in `adb logcat -b crash`.

1. Ride notification: appears at ride start, buttons work, SOS button opens the hold-to-send screen over the lock screen.
2. Crash alarm: full-screen alarm over the lock screen (Android 14+: with and without full-screen permission ->
   heads-up), "I'm OK" and "Send now" from the lock screen, sound through Do Not Disturb when allowed.
3. Another rider's SOS: urgent alert activity over the lock screen.
4. Emergency texts: queue sends after an unanswered crash alarm / SOS; sent and delivered reports; the queue resumes
   after a reboot (`EmergencyTextReceiver` on boot).
5. Foreground service: starts with the ride (location), adds microphone with the intercom, survives 30 min screen
   off, stops at ride end; restarts after reboot if a ride was running.
6. Microphone recording + intercom both ways, noise reduction Strong (native voice library), Bluetooth headset.
7. Google sign-in (new account and returning), sign-out.
8. Quick settings tile -> Medical ID over the lock screen.
9. Plan expiry reminder (schedule one, reboot, it still fires) — exercises the Gson path of flutter_local_notifications.
10. Lock-screen cockpit, app lock (fingerprint / screen lock), Android 16 Live Update (status bar chip).
11. Push notification while the app is closed (FCM, `CoRouteMessagingService`).
12. Share text to CoRoute from Google Maps; invite link `https://.../join/CODE` opens the app.
13. Rate CoRoute (In-App Review sheet), take a photo with the camera and pick from the gallery, share the
    diagnostics log.
14. Spoken alerts (TTS) in English, Hindi and Telugu.

Any crash: retrace with `mapping.txt`, add the narrowest keep with a comment, rebuild, run the list again.
