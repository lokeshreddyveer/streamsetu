using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace StreamSetu.App;

/// <summary>Windows notifications for reminders. If Windows will not show one for this program, the reminder is shown inside the app instead, so it is never lost.</summary>
internal static class Notifier
{
    private static bool _ready;

    public static void Start()
    {
        try { AppNotificationManager.Default.Register(); _ready = true; }
        catch (Exception) { _ready = false; }
    }

    public static void Stop() { try { if (_ready) AppNotificationManager.Default.Unregister(); } catch (Exception) { } }

    /// <summary>Returns true when Windows showed it.</summary>
    public static bool Show(string title, string text)
    {
        if (!_ready) return false;
        try { AppNotificationManager.Default.Show(new AppNotificationBuilder().AddText(title).AddText(text).BuildNotification()); return true; }
        catch (Exception) { return false; }
    }
}
