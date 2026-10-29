plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.android) apply false
    alias(libs.plugins.kotlin.compose) apply false
    alias(libs.plugins.kotlin.serialization) apply false
    alias(libs.plugins.ksp) apply false
    alias(libs.plugins.hilt) apply false
}

// Lint is part of the release gate (android/release.sh). The findings that were already in the code when the gate was added are recorded in each module's lint-baseline.xml, so the
// gate stops a release for anything new and the older ones can be worked through over time (refresh with: ./gradlew updateLintBaseline).
subprojects {
    plugins.withId("com.android.application") {
        extensions.configure<com.android.build.api.dsl.ApplicationExtension> { lint { baseline = file("lint-baseline.xml"); disable += "AutoboxingStateCreation" } }
    }
    plugins.withId("com.android.library") {
        extensions.configure<com.android.build.api.dsl.LibraryExtension> { lint { baseline = file("lint-baseline.xml"); disable += "AutoboxingStateCreation" } }
    }
}
