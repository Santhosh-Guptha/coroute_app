# CoRoute R8 rules (release builds only). Why each rule is here, and what was removed in v3.57:
# docs/release/R8_KEEP_RULES_v3.57.md
#
# ---------------------------------------------------------------------------------------------------
# IF A RELEASE BUILD CRASHES (or a feature silently does nothing) BUT THE DEBUG BUILD WORKS
# ---------------------------------------------------------------------------------------------------
# 1. Get the stack trace: `adb logcat -b crash` (or Play Console > Android vitals for a store build).
# 2. De-obfuscate it with the mapping file of THAT build (keep it with every release you upload):
#      build/app/outputs/mapping/release/mapping.txt
#      $ANDROID_HOME/cmdline-tools/latest/bin/retrace build/app/outputs/mapping/release/mapping.txt stack.txt
#    (Play Console does this automatically once mapping.txt is uploaded with the bundle.)
# 3. Find the class R8 removed or renamed. Check why something is (or is not) kept by adding,
#    temporarily, for example:
#      -whyareyoukeeping class com.pravera.flutter_foreground_task.service.ForegroundService
#      -printconfiguration build/app/outputs/mapping/release/configuration.txt
#      -printusage build/app/outputs/mapping/release/usage.txt     (what was removed)
#    and run `flutter build appbundle --release` again; the answer is printed in the Gradle log.
# 4. Add the NARROWEST rule that fixes it (one class, or only its members used by name), with a
#    comment saying which feature needed it, and add that feature to the release-build device test
#    list in docs/release/R8_KEEP_RULES_v3.57.md. Never turn minify or obfuscation off to make a
#    crash go away, and never go back to `-keep class some.package.** { *; }`.
# ---------------------------------------------------------------------------------------------------
#
# What is kept WITHOUT a rule here (do not add rules for these):
#  - Every activity, service, receiver and the quick settings tile named in AndroidManifest.xml
#    (ours and the plugins' own manifests): AGP generates keep rules for manifest components.
#  - Flutter embedding: flutter_tools adds flutter_proguard_rules.pro (keeps every FlutterPlugin
#    implementation); the engine's JNI entry points are annotated @Keep in the embedding.
#  - Plugins and libraries that ship consumer rules inside their AAR/JAR: Firebase Messaging, Play
#    services (auth/sign-in, basement), Play In-App Review, AndroidX, Gson 2.12 (bundled
#    META-INF/proguard rules: TypeToken, @SerializedName), flutter_local_notifications 19 (its
#    Gson model classes are annotated @Keep), geolocator, permission_handler, image_picker,
#    sqflite, url_launcher, share_plus, path_provider (jni), shared_preferences.
#  - Our own Kotlin (space.devmonks.coroute_app): no class of ours is looked up by name. Platform
#    channels are registered in code (MethodChannel/EventChannel objects), JNI is not used (the voice
#    library is called from Dart through dart:ffi, by C symbol, not by Java name), Kotlin uses
#    org.json (framework) and no Gson/serialization of our classes. RideNotification.kt reflects
#    only on FRAMEWORK classes (Notification.Builder, Notification.ProgressStyle,
#    NotificationManager): R8 never renames or removes android.* classes, so nothing is needed.

# --- Gson generic signatures (flutter_local_notifications: scheduled plan-expiry reminders) -------
# Gson 2.12 ships its own rules; Signature is kept as a cheap belt-and-braces for the plugin's
# generic TypeToken reads of its scheduled-notification cache. Attributes do not stop R8 from
# shrinking, renaming or optimizing code.
-keepattributes Signature

# --- Credential Manager (only if androidx.credentials is on the classpath) -------------------------
# androidx.credentials loads its Play services provider by reflection. Documented rule:
# https://developer.android.com/identity/sign-in/credential-manager#proguard
# The `-if` makes it a no-op while google_sign_in 6.x (Play services auth, no Credential Manager)
# is used, and correct when google_sign_in 7 / Credential Manager arrives.
-if class androidx.credentials.CredentialManager
-keep class androidx.credentials.playservices.** {
  *;
}

# --- Logging -----------------------------------------------------------------------------------
# Verbose/debug logcat calls are removed from release code (mostly library chatter). The diagnostics
# log (DiagLog, pure Dart, written to files) does not use android.util.Log; our Kotlin logs with
# Log.i (TtsChannel diagnostic lines) and Log.w (emergency texts, crash log, voice codec) only,
# which stay untouched. Methods are named exactly (never `{ *; }`).
-assumenosideeffects class android.util.Log {
    public static int v(java.lang.String, java.lang.String);
    public static int v(java.lang.String, java.lang.String, java.lang.Throwable);
    public static int d(java.lang.String, java.lang.String);
    public static int d(java.lang.String, java.lang.String, java.lang.Throwable);
}

# --- Warnings only (missing optional classes; no effect on what is kept) --------------------------
-dontwarn io.flutter.embedding.**
# Flutter references Play Core (deferred components) that this app does not ship.
-dontwarn com.google.android.play.core.**
-dontwarn javax.annotation.**
-dontwarn com.google.android.gms.**
# R8 full mode (AGP 9): annotations only referenced at compile time.
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.lang.model.**
-dontwarn org.conscrypt.**
