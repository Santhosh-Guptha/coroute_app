import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing comes from android/key.properties (git-ignored, never committed):
//   storeFile=coroute.jks
//   storePassword=...
//   keyAlias=coroute_key
//   keyPassword=...
// Or from environment variables COROUTE_STORE_FILE / COROUTE_STORE_PASSWORD / COROUTE_KEY_ALIAS / COROUTE_KEY_PASSWORD (CI).
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) load(FileInputStream(f))
}
fun signingValue(key: String, env: String): String? =
    keystoreProperties.getProperty(key) ?: System.getenv(env)

// 3.54 (Play release readiness): a release package must be signed with the upload key. When
// key.properties (or the CI variables) is missing or incomplete, or the keystore file is not
// there, a release assemble/bundle/install FAILS here instead of silently using the debug key.
// Only presence is checked; no value is read out or printed.
val releaseSigningReady: Boolean = run {
    val storePath = signingValue("storeFile", "COROUTE_STORE_FILE")
    storePath != null && file(storePath).exists() &&
        signingValue("storePassword", "COROUTE_STORE_PASSWORD") != null &&
        signingValue("keyAlias", "COROUTE_KEY_ALIAS") != null &&
        signingValue("keyPassword", "COROUTE_KEY_PASSWORD") != null
}
val releasePackagingRequested: Boolean = gradle.startParameter.taskNames.any { task ->
    val name = task.substringAfterLast(':')
    name.contains("Release") && listOf("assemble", "bundle", "package", "install", "sign").any { name.startsWith(it) }
}
if (releasePackagingRequested && !releaseSigningReady) {
    throw GradleException(
        "Release signing is not configured: android/key.properties (or COROUTE_STORE_FILE, " +
            "COROUTE_STORE_PASSWORD, COROUTE_KEY_ALIAS, COROUTE_KEY_PASSWORD) is missing or incomplete, " +
            "or the keystore file was not found. A release build is never signed with the debug key. " +
            "See android/key.properties.example."
    )
}

// 3.55 push notifications (Firebase Cloud Messaging, docs/features_355/push_notifications.md).
// The four Firebase client values come from gradle properties (-PCOROUTE_FCM_APP_ID=... or
// ~/.gradle/gradle.properties) or the environment (CI). They are never committed. Without all four
// the app builds and runs normally with push turned off (FirebaseApp is never initialised).
fun fcmValue(name: String): String =
    ((project.findProperty(name) as String?) ?: System.getenv(name) ?: "").trim()
val fcmAppId = fcmValue("COROUTE_FCM_APP_ID")
val fcmApiKey = fcmValue("COROUTE_FCM_API_KEY")
val fcmProjectId = fcmValue("COROUTE_FCM_PROJECT_ID")
val fcmSenderId = fcmValue("COROUTE_FCM_SENDER_ID")
val fcmConfigured = listOf(fcmAppId, fcmApiKey, fcmProjectId, fcmSenderId).all { it.isNotEmpty() }

android {
    namespace = "space.devmonks.coroute_app"
    // compileSdk stays 37 (raised on purpose in 3d96e53 for the release build); it may be higher
    // than targetSdk. targetSdk is pinned to 36 (Play: API 36 for app updates from 31 Aug 2026)
    // instead of following the Flutter SDK default.
    compileSdk = 37
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications (java.time on older Android versions).
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "space.devmonks.coroute_app"
        // Effective minimum: API 24 (Android 7.0). Flutter's own minimum is 24, so the floor here is
        // 24 too (it was 23 before v3.57; the result did not change). Kotlin guards for API 23 stay
        // and are harmless. Public texts say "Android 7.0 or newer".
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // 3.55 push: read by PushConfig (PushChannel.kt); empty strings = push off.
        resValue("string", "coroute_fcm_app_id", fcmAppId)
        resValue("string", "coroute_fcm_api_key", fcmApiKey)
        resValue("string", "coroute_fcm_project_id", fcmProjectId)
        resValue("string", "coroute_fcm_sender_id", fcmSenderId)
        // v3.57 build health (docs/release/PLAY_BUILD_HEALTH_PLAN_v3.57.md section 5): build
        // libcoroute_voice.so for every ABI the bundle ships. This filter only chooses what CMake
        // compiles (it is not ndk.abiFilters, so it does not clash with --split-per-abi or with
        // Flutter's --target-platform; Gradle builds the ABIs present in both).
        // ANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES: 16 KB ELF alignment (default since NDK r28; explicit so
        // an older NDK cannot silently produce a 4 KB-only library). CMakeLists.txt also links with
        // -z max-page-size=16384. Check a built APK/AAB with tool/check_16kb_alignment.sh.
        externalNativeBuild {
            cmake {
                abiFilters += listOf("arm64-v8a", "armeabi-v7a", "x86_64")
                arguments += listOf("-DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON")
            }
        }
        if (fcmConfigured) {
            // The standard names let Firebase initialise itself at process start, so a push that
            // wakes a closed app is handled before any CoRoute code runs.
            resValue("string", "google_app_id", fcmAppId)
            resValue("string", "google_api_key", fcmApiKey)
            resValue("string", "project_id", fcmProjectId)
            resValue("string", "gcm_defaultSenderId", fcmSenderId)
        }
    }

    buildFeatures {
        resValues = true
    }

    // v3.57 build health (plan section 3): ship resources only for the languages CoRoute offers or has
    // planned (English, Hindi, Telugu; Tamil, Kannada, Malayalam, Marathi), instead of the ~85 locales
    // AndroidX / Play services bring. CoRoute's own text is in Dart and is not affected; library
    // dialogs (for example Google sign-in) fall back to English in any other locale.
    // Add a language HERE before offering it in Settings > Language.
    // localeFilters is the AGP 8.7+ name (this project uses AGP 9.0.1, settings.gradle.kts); on older
    // AGP it was defaultConfig { resourceConfigurations += ... }.
    androidResources {
        localeFilters += listOf("en", "hi", "te", "ta", "kn", "ml", "mr")
    }

    // Round 8: native intercom voice cleanup, libcoroute_voice.so (RNNoise, BSD-3-Clause; src/main/cpp).
    // Loaded from Dart with dart:ffi (lib/data/services/voice/voice_native_ffi.dart); no JNI.
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    signingConfigs {
        create("release") {
            val storePath = signingValue("storeFile", "COROUTE_STORE_FILE")
            if (storePath != null) {
                storeFile = file(storePath)
                storePassword = signingValue("storePassword", "COROUTE_STORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "COROUTE_KEY_ALIAS")
                keyPassword = signingValue("keyPassword", "COROUTE_KEY_PASSWORD")
                enableV1Signing = true
                enableV2Signing = true
            }
        }
    }

    buildTypes {
        release {
            // The upload key only. Without it, release packaging tasks fail above; the debug config is
            // kept here only so non-packaging tasks (lint, dependency reports) still configure.
            signingConfig = if (releaseSigningReady) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
            // R8 (full mode) shrinks, optimizes and obfuscates the Java/Kotlin code and removes unused
            // resources. v3.57: proguard-rules.pro no longer keeps whole packages; it relies on the
            // libraries' own consumer rules plus a few narrow rules (docs/release/R8_KEEP_RULES_v3.57.md).
            // If a release build crashes, follow the procedure at the top of proguard-rules.pro and add
            // the narrowest keep: do not turn minify or obfuscation off.
            // Upload build/app/outputs/mapping/release/mapping.txt with every bundle (Play crash
            // de-obfuscation); flutter build appbundle includes it in the .aab automatically.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            // Native debug symbols (libcoroute_voice.so, Flutter engine) go into the .aab for Play's
            // native crash symbolication. SYMBOL_TABLE keeps function names only (smaller than FULL).
            ndk {
                debugSymbolLevel = "SYMBOL_TABLE"
            }
        }
    }

    // Store native libraries compressed in the sideloaded APK (with minSdk 23 or higher AGP would leave
    // them uncompressed, which is most of the APK size). Build with --split-per-abi for one APK per CPU.
    // AGP also passes this setting to the bundle config (uncompressNativeLibraries = false), so Play's
    // APKs may carry compressed libraries too. That is fine for 16 KB devices: compressed libraries
    // are extracted at install and only their ELF alignment matters (tool/check_16kb_alignment.sh);
    // the zip-level 16 KB alignment applies to uncompressed libraries only.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // 3.55 push notifications: FCM only (no Analytics). Configured at build time, see above.
    implementation(platform("com.google.firebase:firebase-bom:33.7.0"))
    implementation("com.google.firebase:firebase-messaging")
    // 3.55 "Rate CoRoute": Google Play In-App Review API (InAppReviewChannel.kt). No billing, no referrer.
    implementation("com.google.android.play:review:2.0.2")
}
