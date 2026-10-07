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
