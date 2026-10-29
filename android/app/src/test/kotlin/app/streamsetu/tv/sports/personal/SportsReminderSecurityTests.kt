package app.streamsetu.tv.sports.personal

import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The doors into Sports reminders: who may deliver an alarm or a tap, what they may name, and how the intents are built. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = android.app.Application::class)
class SportsReminderSecurityTests {
    private val context get() = ApplicationProvider.getApplicationContext<android.content.Context>()
    private val manifest get() = java.io.File("src/main/AndroidManifest.xml").readText()
    private fun receiver(name: String): String = Regex("<receiver[^>]*android:name=\"$name\"[^>]*?(/>|>.*?</receiver>)", RegexOption.DOT_MATCHES_ALL).find(manifest)!!.value

    @Test fun theSportsReceiversAreNotExported() {
        assertTrue(receiver("\\.sports\\.personal\\.SportsReminderReceiver").contains("android:exported=\"false\""))
        assertTrue("the system delivers its own broadcasts to a receiver that is not exported", receiver("\\.sports\\.personal\\.SportsRescheduleReceiver").contains("android:exported=\"false\""))
    }

    @Test fun theRescheduleReceiverListensToExactlyTheThreeSystemBroadcasts() {
        val actions = Regex("android:name=\"(android\\.intent\\.action\\.[A-Z_]+)\"").findAll(receiver("\\.sports\\.personal\\.SportsRescheduleReceiver")).map { it.groupValues[1] }.toSet()
        assertEquals(setOf("android.intent.action.BOOT_COMPLETED", "android.intent.action.MY_PACKAGE_REPLACED", "android.intent.action.TIMEZONE_CHANGED"), actions)
        assertFalse("the alarm receiver has no intent filter at all", receiver("\\.sports\\.personal\\.SportsReminderReceiver").contains("intent-filter"))
    }

    @Test fun anAlarmNamesItsReminderOnlyByItsAddress() {
        val scheduler = AlarmReminderScheduler(context)
        val own = scheduler.intentFor("abc-123")
        assertEquals("abc-123", AlarmReminderScheduler.idFrom(own)); assertNull("no extras at all", own.extras)
        assertEquals("an extra naming another reminder is ignored", "abc-123", AlarmReminderScheduler.idFrom(Intent(own).putExtra("id", "someone-elses").putExtra("profile", "kid")))
        assertNull(AlarmReminderScheduler.idFrom(Intent(own).setAction("android.intent.action.VIEW")))
        assertNull(AlarmReminderScheduler.idFrom(Intent(own).setData(android.net.Uri.parse("https://example.com/abc-123"))))
        assertNull(AlarmReminderScheduler.idFrom(Intent(AlarmReminderScheduler.ACTION).putExtra("id", "abc-123")))                  // an extra alone selects nothing
        assertNull(AlarmReminderScheduler.idFrom(null))
        assertNull(AlarmReminderScheduler.idFrom(scheduler.intentFor("x".repeat(65))))
    }

    @Test fun anUnexpectedBroadcastIsIgnoredByBothReceivers() {
        SportsReminderReceiver().onReceive(context, Intent("evil.action").putExtra("id", "x"))
        SportsReminderReceiver().onReceive(context, Intent(AlarmReminderScheduler.ACTION).putExtra("id", "x"))                  // right action, no address
        SportsRescheduleReceiver().onReceive(context, Intent(Intent.ACTION_VIEW)); SportsRescheduleReceiver().onReceive(context, Intent("evil.action"))
    }

    @Test fun everyReminderHasItsOwnPendingIntentAndTheyAreImmutable() {
        val scheduler = AlarmReminderScheduler(context); val notifier = AndroidReminderNotifier(context) { }
        assertTrue(scheduler.intentFor("a").filterEquals(scheduler.intentFor("a"))); assertFalse("two reminders never share an alarm", scheduler.intentFor("a").filterEquals(scheduler.intentFor("b")))
        assertFalse("nor a tap", notifier.openIntent("a").filterEquals(notifier.openIntent("b"))); assertNull(notifier.openIntent("a").extras)
        val src = java.io.File("src/main/kotlin/app/streamsetu/tv/sports/personal/RealReminderDeps.kt").readText()
        val builders = Regex("PendingIntent\\.get(Broadcast|Activity)\\([^\\n]*").findAll(src).map { it.value }.toList()
        assertTrue(builders.size >= 2); assertTrue("every pending intent is immutable: $builders", builders.all { "FLAG_IMMUTABLE" in it })
    }

    @Test fun aTapNamesItsReminderOnlyByItsAddress() {
        val notifier = AndroidReminderNotifier(context) { }
        val own = notifier.openIntent("abc-123")
        assertEquals("abc-123", AndroidReminderNotifier.openIdFrom(own))
        assertEquals("extras cannot redirect it", "abc-123", AndroidReminderNotifier.openIdFrom(Intent(own).putExtra("sportsReminder", "other").putExtra("profile", "kid")))
        assertNull(AndroidReminderNotifier.openIdFrom(Intent(Intent.ACTION_MAIN).putExtra("sportsReminder", "abc-123")))
        assertNull(AndroidReminderNotifier.openIdFrom(Intent(own).setData(android.net.Uri.parse("streamsetu://play?id=abc-123"))))
        assertNull(AndroidReminderNotifier.openIdFrom(null))
    }

    @Test fun theNotificationAndTheMainScreenCarryNoReminderOrProfileInExtras() {
        val src = java.io.File("src/main/kotlin/app/streamsetu/tv/sports/personal/RealReminderDeps.kt").readText()
        assertFalse("no putExtra anywhere in the reminder intents", src.contains("putExtra"))
        val main = java.io.File("src/main/kotlin/app/streamsetu/tv/MainActivity.kt").readText()
        assertTrue(main.contains("AndroidReminderNotifier.openIdFrom(intent)")); assertFalse(main.contains("getStringExtra(app.streamsetu.tv.sports"))
    }
}
