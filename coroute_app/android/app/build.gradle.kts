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
        minSdk = maxOf(flutter.minSdkVersion, 23)
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // 3.55 push: read by PushConfig (PushChannel.kt); empty strings = push off.
        resValue("string", "coroute_fcm_app_id", fcmAppId)
        resValue("string", "coroute_fcm_api_key", fcmApiKey)
        resValue("string", "coroute_fcm_project_id", fcmProjectId)
        resValue("string", "coroute_fcm_sender_id", fcmSenderId)
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
            // R8 shrinks the Java/Kotlin code and unused resources. proguard-rules.pro keeps the
            // plugins that use reflection (notifications, foreground service, recorder, Google auth).
            // If a plugin misbehaves on a device, set both back to false: split-per-abi below and
            // compressed native libraries give most of the size saving on their own.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            ndk {
                debugSymbolLevel = "none"
            }
        }
    }

    // Store native libraries compressed in the sideloaded APK (minSdk 23 would leave them
    // uncompressed, which is most of the APK size). Build with --split-per-abi for one APK per CPU.
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
}
