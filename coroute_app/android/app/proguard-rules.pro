# Flutter / plugins
-keep class io.flutter.** { *; }
-keep class com.google.android.gms.auth.** { *; }
-dontwarn io.flutter.embedding.**

# flutter_local_notifications (uses Gson with generic types for scheduled notifications)
-keep class com.dexterous.** { *; }
-keep class com.google.gson.** { *; }
-keepattributes Signature, *Annotation*

# Foreground service (position sharing and intercom with the screen locked)
-keep class com.pravera.flutter_foreground_task.** { *; }

# Microphone recorder (intercom)
-keep class com.llfbandit.record.** { *; }

# Flutter references Play Core (deferred components) that this app does not ship
-dontwarn com.google.android.play.core.**

# Razorpay Checkout SDK
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
-keepattributes JavascriptInterface
-keepclassmembers class com.razorpay.RazorpayHttpCallback {
    *;
}
-keep class com.razorpay.** { *; }
-dontwarn com.razorpay.**
-dontwarn javax.annotation.**

# Razorpay (official rules): payment callbacks are found by name.
-keepclasseswithmembers class * {
    public void onPayment*(...);
}
-dontwarn proguard.annotation.Keep
-dontwarn proguard.annotation.KeepClassMembers

# The app's own platform channels (crash sensor, SMS composer, TTS, safety window, tiles).
-keep class space.devmonks.coroute_app.** { *; }

# google_sign_in (Credential Manager / Play services auth)
-keep class androidx.credentials.playservices.** { *; }
-dontwarn com.google.android.gms.**

# image_picker (camera via ACTION_IMAGE_CAPTURE, Android photo picker): plugin ships its own
# consumer rules; geolocator, permission_handler, sqflite, flutter_secure_storage, url_launcher,
# share_plus, wakelock_plus, battery_plus, package_info_plus and app_links do too.
# R8 full mode (AGP 9): annotations only referenced at compile time.
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.lang.model.**
-dontwarn org.conscrypt.**
