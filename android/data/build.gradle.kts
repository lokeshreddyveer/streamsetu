plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.serialization)

}

android {
    namespace = "app.streamsetu.core.data"
    compileSdk = 35
    defaultConfig { minSdk = 22 }
    compileOptions {
        // java.time and newer java.util methods are used here; the app module desugars them for Android 5.1 and up, and this tells this module's own lint check the same.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    testOptions {
        unitTests.isReturnDefaultValues = true
        // Sports is switched off in the app, so its tests are left out of the gate; `-PwithSports` runs them.
        unitTests.all { t -> if (!project.hasProperty("withSports")) t.filter { excludeTestsMatching("app.streamsetu.core.sports.*") } }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    api(project(":core-model"))
    api(project(":core-security"))
    api(project(":core-network"))
    api(project(":core-database"))
    api(project(":core-preferences"))
    api(project(":core-media"))
    implementation(libs.androidx.core.ktx)
    implementation(libs.kotlinx.coroutines.android)

    testImplementation(libs.junit)
    testImplementation(libs.okhttp.mockwebserver)
}
