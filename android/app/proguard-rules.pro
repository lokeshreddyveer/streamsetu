-keep class androidx.media3.** { *; }
-dontwarn org.slf4j.**

# libmpv reaches these from native code
-keep class dev.jdtech.mpv.** { *; }
-keep class is.xyz.mpv.** { *; }
# Room, Hilt, WorkManager workers are created by name
-keep class * extends androidx.work.ListenableWorker { <init>(...); }
-keep class app.streamsetu.tv.CatalogSyncWorker { *; }
# Parsers read these by reflection-free code but keep readable crash notes
-keepattributes SourceFile,LineNumberTable
-dontwarn org.slf4j.**
-dontwarn javax.annotation.**
