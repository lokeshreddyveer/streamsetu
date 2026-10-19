plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.serialization)

}

android {
    namespace = "app.streamsetu.core.network"
    compileSdk = 35
    defaultConfig { minSdk = 22 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    testOptions { unitTests.isReturnDefaultValues = true }
}

dependencies {
    api(project(":core-model"))
    implementation(libs.kotlinx.coroutines.android)
    api(libs.kotlinx.serialization.json)
    api(libs.okhttp)
    api(libs.retrofit)
    api(libs.retrofit.serialization)

    testImplementation(libs.junit)
    testImplementation(libs.okhttp.mockwebserver)

}

// A TV stick has little memory: the tests run with a small heap, so a list read whole instead of as a stream fails here as it would there.
tasks.withType<Test>().configureEach { maxHeapSize = "128m" }
