import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing (v1.0.4, audit F6 — previously the debug key).
// The upload keystore and its passwords live OUTSIDE the repo, in
// ~/.kanakku-signing/ (or wherever $KANAKKU_KEY_PROPERTIES points).
// When the properties file is absent (another machine, CI), release
// builds fall back to the debug key so the project still builds.
val kanakkuKeyPropsFile =
    System.getenv("KANAKKU_KEY_PROPERTIES")?.let { file(it) }
        ?: file("/home/hatch/.kanakku-signing/key.properties")
val kanakkuKeyProperties = Properties()
val kanakkuHasReleaseKey = kanakkuKeyPropsFile.exists()
if (kanakkuHasReleaseKey) {
    kanakkuKeyPropsFile.inputStream().use { kanakkuKeyProperties.load(it) }
}

android {
    namespace = "in.kanakku.kanakku"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "in.kanakku.kanakku"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (kanakkuHasReleaseKey) {
                storeFile = file(kanakkuKeyProperties.getProperty("storeFile"))
                storePassword = kanakkuKeyProperties.getProperty("storePassword")
                keyAlias = kanakkuKeyProperties.getProperty("keyAlias")
                keyPassword = kanakkuKeyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Real upload key when available (see above); debug
            // fallback keeps `flutter run --release` working on
            // machines without the keystore.
            signingConfig = if (kanakkuHasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    lint {
        // v0.1 sideload builds: skip release lint (its artifact tree is huge);
        // re-enable before any Play Store upload.
        checkReleaseBuilds = false
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
