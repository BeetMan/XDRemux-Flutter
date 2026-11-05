import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val signingProperties = Properties()
val signingPropertiesFile = rootProject.file("key.properties")
if (signingPropertiesFile.isFile) {
    signingPropertiesFile.inputStream().use { signingProperties.load(it) }
}

fun signingProperty(name: String): String? =
    signingProperties.getProperty(name)?.takeIf { it.isNotBlank() }

val releaseStoreFile = signingProperty("storeFile")?.let { rootProject.file(it) }
val releaseStorePassword = signingProperty("storePassword")
val releaseKeyAlias = signingProperty("keyAlias")
val releaseKeyPassword = signingProperty("keyPassword")
val releaseSigningConfigured = releaseStoreFile?.isFile == true &&
    releaseStorePassword != null &&
    releaseKeyAlias != null &&
    releaseKeyPassword != null

if (System.getenv("XDREMUX_REQUIRE_RELEASE_SIGNING") == "true" && !releaseSigningConfigured) {
    throw GradleException(
        "Release signing is required, but android/key.properties and its keystore are not configured.",
    )
}

android {
    namespace = "com.example.xdremux"
    // Keep the release build on the stable Android 36 SDK available on
    // GitHub-hosted runners; this is independent of the app target SDK.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications requires core library desugaring.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "io.github.beetman.xdremux"
        manifestPlaceholders["transferAppLabel"] = if (System.getenv("XDREMUX_TRANSFER_TEST_APP") == "true")
            "XDRemux Transfer Test" else "XDRemux"
        // Isolated device validation alongside the user's installed app.
        if (System.getenv("XDREMUX_TRANSFER_TEST_APP") == "true") {
            applicationIdSuffix = ".transferdev"
        }
        minSdk = 24
        targetSdk = 36 // SDK 37 requires a separate ACCESS_LOCAL_NETWORK runtime flow.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            // Flutter 3.35+ pre-populates three ABIs. Adding ARM64 alone does
            // not remove the others, but our Rust core only ships for ARM64.
            abiFilters.clear()
            abiFilters += listOf("arm64-v8a")
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    signingConfigs {
        if (releaseSigningConfigured) {
            create("release") {
                storeFile = releaseStoreFile
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            // Local builds fall back to debug only when no release key is configured.
            // CI sets XDREMUX_REQUIRE_RELEASE_SIGNING and must use the shared key.
            signingConfig = if (releaseSigningConfigured) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

// Separately built optional native capability; ordinary image builds do not invoke Cargo.
val transferSoOverride = System.getenv("XDREMUX_ANDROID_TRANSFER_SO")
val transferSo = if (!transferSoOverride.isNullOrBlank()) file(transferSoOverride) else
    rootProject.file("../../../crates/xdremux-transfer-ffi/target/aarch64-linux-android/release/libxdremux_transfer.so")
if (!transferSoOverride.isNullOrBlank() && !transferSo.isFile) {
    throw GradleException("Explicit transfer library does not exist")
}
if (transferSo.isFile) {
    val transferJni = layout.buildDirectory.dir("generated/localTransfer/jni")
    val transferAssets = layout.buildDirectory.dir("generated/localTransfer/assets")
    // Materialized paths plus explicit preBuild dependencies (AGP 9 disallows Providers here).
    android.sourceSets.getByName("main").jniLibs.srcDir(transferJni.get().asFile)
    android.sourceSets.getByName("main").assets.srcDir(transferAssets.get().asFile)
    val copyTransfer = tasks.register<Copy>("copyTransferLibrary") {
        from(transferSo); into(transferJni.map { it.dir("arm64-v8a") })
    }
    val copyTransferLicense = tasks.register<Copy>("copyTransferLicense") {
        from(rootProject.file("../../../crates/xdremux-transfer/vendor/localsend/LICENSE"))
        into(transferAssets.map { it.dir("licenses") }); rename { "LocalSend-Apache-2.0.txt" }
    }
    tasks.named("preBuild").configure { dependsOn(copyTransfer, copyTransferLicense) }
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
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    if (System.getenv("XDREMUX_TRANSFER_TEST_APP") == "true") {
        // Flutter excludes dev plugins from release APKs. This isolated test target
        // needs IntegrationTestPlugin; the production application never links it.
        implementation(project(":integration_test"))
    }
}
