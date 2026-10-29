plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.android)

}

android {
    namespace = "app.streamsetu.core.media"
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
    api(project(":core-network"))
    api(project(":core-preferences"))
    implementation(libs.androidx.core.ktx)
    implementation(libs.kotlinx.coroutines.android)
    api(libs.media3.exoplayer)
    api(libs.media3.exoplayer.hls)
    api(libs.media3.exoplayer.dash)
    api(libs.media3.datasource.okhttp)
    api(libs.libmpv)
    api(libs.media3.ui)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)

}
