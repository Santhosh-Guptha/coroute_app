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

android {
    namespace = "space.devmonks.coroute_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "space.devmonks.coroute_app"
        minSdk = maxOf(flutter.minSdkVersion, 23)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            val storePath = signingValue("storeFile", "COROUTE_STORE_FILE")
            if (storePath != null) {
                storeFile = file(storePath)
                storePassword = signingValue("storePassword", "COROUTE_STORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "COROUTE_KEY_ALIAS")
                keyPassword = signingValue("keyPassword", "COROUTE_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // Falls back to the debug key when key.properties is absent so `flutter run --release` still works locally.
            signingConfig = if (signingValue("storeFile", "COROUTE_STORE_FILE") != null) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
            // Code shrinking is left off for predictable releases; flip both to true once you have
            // smoke-tested a shrunk build on a device (proguard-rules.pro already keeps Flutter + Google auth).
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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
