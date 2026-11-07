using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using StreamSetu.Core;
using WinRT.Interop;

namespace StreamSetu.App;

public sealed partial class MainWindow : Window
{
    private bool _started;

    public MainWindow()
    {
        InitializeComponent();
        AppServices.MainWindow = this;
        AppServices.MainHandle = WindowNative.GetWindowHandle(this);
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1280, 800));
        Closed += (_, _) => { AppServices.Session?.Stop(); AppServices.Mpv?.Dispose(); };
    }

    /// <summary>The first thing on screen is who is watching: the profile to use (and its PIN, if it has one). With a single profile and no PIN there is nothing to ask.</summary>
    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (_started) return;
        _started = true;
        StartBackgroundServices();
        try { await ChooseProfileAsync(first: true); }
        catch (Exception ex) { await Dialogs.MessageAsync(Nav.XamlRoot, "StreamSetu", ex.Message); }
        GoHome();
    }

    private readonly DispatcherTimer _reminders = new() { Interval = TimeSpan.FromSeconds(30) };

    /// <summary>Things that run while the app is open: reminders that notify, scheduled recordings, and sync with the other devices.</summary>
    private void StartBackgroundServices()
    {
        Notifier.Start();
        RecordingService.Start(DispatcherQueue);
        AppServices.Lan = new LanService(DispatcherQueue) { Confirm = (digits, peer) => Dialogs.ConfirmAsync(Nav.XamlRoot, "Add a device", $"Does {peer} show the same six digits?\n\n{digits}\n\nOnly say yes if they match exactly.", "They match") };
        if (AppServices.Settings.LanSync) _ = AppServices.Lan.StartAsync();
        _reminders.Tick += async (_, _) => await CheckRemindersAsync();
        _reminders.Start();
        Closed += (_, _) => { _reminders.Stop(); RecordingService.StopAll(); Notifier.Stop(); _ = AppServices.Lan?.StopAsync(); };
    }

    private async Task CheckRemindersAsync()
    {
        foreach (var r in AppServices.Reminders.Due(DateTimeOffset.UtcNow))
        {
            AppServices.Reminders.MarkFired(r.Id);
            var text = $"{r.Title} on {r.Channel} at {r.Start.ToLocalTime():HH:mm}";
            if (!Notifier.Show("Starting soon", text)) await Dialogs.MessageAsync(Nav.XamlRoot, "Starting soon", text);       // if Windows will not show a notification, the app does
        }
        AppServices.Reminders.Prune(DateTimeOffset.UtcNow);
    }

    private void GoHome()
    {
        var first = AppServices.Store.Playlists().Count == 0 && !AppServices.Profile.Kids ? "connections" : "live";
        foreach (var item in Nav.MenuItems.Concat(Nav.FooterMenuItems).OfType<NavigationViewItem>())
            if ((string)item.Tag == first) { Nav.SelectedItem = item; break; }
    }

    /// <summary>Asks which profile, then its PIN. Cancelling the PIN on a later switch keeps the current profile; at start it asks again, because the app cannot be used without one.</summary>
    public async Task ChooseProfileAsync(bool first = false)
    {
        var all = AppServices.Profiles.All();
        while (true)
        {
            Profile chosen;
            if (all.Count == 1) chosen = all[0];
            else
            {
                var list = new ListView { SelectionMode = ListViewSelectionMode.Single, ItemsSource = all.Select(p => p.Name + (p.Kids ? "  (Kids)" : "") + (p.Pin is not null ? "  🔒" : "")).ToList(), SelectedIndex = Math.Max(0, all.FindIndex(p => p.Id == AppServices.Profile.Id)) };
                var dialog = new ContentDialog { Title = "Who is watching?", Content = list, PrimaryButtonText = "Continue", DefaultButton = ContentDialogButton.Primary, XamlRoot = Nav.XamlRoot };
                if (!first) dialog.CloseButtonText = "Cancel";
                if (await dialog.ShowAsync() != ContentDialogResult.Primary) { if (first) continue; return; }
                chosen = all[Math.Max(0, list.SelectedIndex)];
            }

            if (chosen.Pin is not null && !await Dialogs.PinAsync(Nav.XamlRoot, $"PIN for {chosen.Name}", pin => AppServices.Profiles.CheckPin(chosen.Id, pin)))
            {
                if (first) continue;       // at start the PIN is the way in, so it is asked for again; later, cancelling keeps the profile already in use
                return;
            }
            AppServices.SignIn(chosen);
            ApplyProfile();
            return;
        }
    }

    /// <summary>A Kids profile cannot reach the places that change connections or settings.</summary>
    private void ApplyProfile()
    {
        var grownUp = !AppServices.Profile.Kids;
        ConnectionsItem.Visibility = SettingsItem.Visibility = grownUp ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>Hides or shows the menu (the mini player hides it).</summary>
    public void SetChromeVisible(bool visible) => Nav.IsPaneVisible = visible;

    public void ShowProfileChanged() { ApplyProfile(); GoHome(); }

    private void OnSelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItemContainer?.Tag is not string tag) return;
        if (AppServices.Profile.Kids && tag is "connections" or "settings") return;
        var page = tag switch { "connections" => typeof(ConnectionsPage), "settings" => typeof(SettingsPage), "guide" => typeof(GuidePage), "multiview" => typeof(MultiViewPage), "recordings" => typeof(RecordingsPage), _ => typeof(BrowsePage) };
        ContentFrame.Navigate(page, tag);
    }
}
