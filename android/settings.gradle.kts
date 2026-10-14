pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "StreamSetuTV"
include(":core-model", ":core-security", ":core-network", ":core-database", ":core-preferences", ":core-media", ":data", ":app")
