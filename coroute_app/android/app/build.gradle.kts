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
            // R8 shrinks the Java/Kotlin code and unused resources. proguard-rules.pro keeps the
            // plugins that use reflection (notifications, foreground service, recorder, Google auth).
            // If a plugin misbehaves on a device, set both back to false: split-per-abi below and
            // compressed native libraries give most of the size saving on their own.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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
}
