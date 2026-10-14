plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.ksp)
    alias(libs.plugins.hilt)
}

import java.util.Properties

// Signing: put the key details in android/keystore.properties (never committed): storeFile, storePassword, keyAlias, keyPassword.
val keystoreProps = Properties().also { p -> rootProject.file("keystore.properties").takeIf { it.exists() }?.inputStream()?.use { p.load(it) } }

android {
    namespace = "app.streamsetu.tv"
    compileSdk = 35
    defaultConfig {
        applicationId = "app.streamsetu.tv"
        minSdk = 22
        targetSdk = 35
        // Override on the command line: -PappVersionCode=12 -PappVersionName=1.0.0
        versionCode = (project.findProperty("appVersionCode") as String?)?.toIntOrNull() ?: 1
        versionName = (project.findProperty("appVersionName") as String?) ?: "0.2.0"
        // In-app updating from GitHub releases. Turn it off (-PselfUpdate=false) for a build that goes through a store, which updates apps itself.
        buildConfigField("boolean", "SELF_UPDATE", ((project.findProperty("selfUpdate") as String?) != "false").toString())
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") }       // Fire TV and Android TV boxes are ARM
    }
    signingConfigs {
        if (keystoreProps.containsKey("storeFile")) create("release") {
            storeFile = rootProject.file(keystoreProps.getProperty("storeFile")); storePassword = keystoreProps.getProperty("storePassword")
            keyAlias = keystoreProps.getProperty("keyAlias"); keyPassword = keystoreProps.getProperty("keyPassword")
        }
    }
    buildTypes {
        // A debuggable build signed with the release key, for trying the in-app updater on a device without uninstalling. Not distributed.
        create("selftest") {
            initWith(getByName("release"))
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
            isDebuggable = true; isMinifyEnabled = false; isShrinkResources = false
            matchingFallbacks += "release"
        }
        release {
            // With no keystore.properties the release build is signed with the debug key, so it can still be installed for testing; it must not be distributed.
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17"; freeCompilerArgs += "-opt-in=androidx.compose.ui.ExperimentalComposeUiApi" }
    buildFeatures { compose = true; buildConfig = true }
    testOptions { unitTests { isIncludeAndroidResources = true; isReturnDefaultValues = true } }       // the Compose UI tests run on the JVM with Robolectric
}

dependencies {
    implementation(project(":data"))
    implementation(project(":core-ui"))
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.navigation.compose)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.compose.material.icons)
    implementation(libs.tv.material)
    implementation(libs.media3.ui)
    implementation(libs.coil.compose)
    implementation(libs.play.services.cast)             // Chromecast, used on phones only (a Fire TV has no Google Play services and never starts it)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.hilt.android)
    ksp(libs.hilt.compiler)
    implementation(libs.hilt.navigation.compose)
    implementation(libs.workmanager)
    implementation(libs.zxing)
    testImplementation(libs.junit)
    testImplementation("org.json:json:20240303")
    testImplementation(platform(libs.compose.bom))
    testImplementation("androidx.compose.ui:ui-test-junit4")
    testImplementation("org.robolectric:robolectric:4.14.1")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
    implementation(libs.profileinstaller)       // installs the precompiled start-up profile (ours and Compose's) so the first scroll is not the slow one
}
