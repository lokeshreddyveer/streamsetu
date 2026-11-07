using System.Diagnostics;
using System.Security.Cryptography.X509Certificates;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using StreamSetu.Core;

namespace StreamSetu.App;

public sealed partial class SettingsPage : Page
{
    private bool _quiet = true;

    public SettingsPage()
    {
        InitializeComponent();
        var s = AppServices.Settings;
        DnsBox.SelectedIndex = s.Dns.Length == 0 ? 0 : s.Dns.Equals("Cloudflare", StringComparison.OrdinalIgnoreCase) ? 1 : s.Dns.Equals("Google", StringComparison.OrdinalIgnoreCase) ? 2 : s.Dns.Equals("Quad9", StringComparison.OrdinalIgnoreCase) ? 3 : 4;
        DnsUrl.Visibility = DnsBox.SelectedIndex == 4 ? Visibility.Visible : Visibility.Collapsed; DnsUrl.Text = DnsBox.SelectedIndex == 4 ? s.Dns : "";
        LanguageBox.Text = s.SubtitleLanguage; AutoBox.IsChecked = s.AutoSubtitles; OsUser.Text = s.OpenSubtitlesUser ?? "";
        OsPass.Password = AppServices.Secrets.Get("opensubtitles:password") ?? ""; OsKey.Password = AppServices.Secrets.Get("opensubtitles:key") ?? "";
        AlertBox.Text = string.Join(", ", s.AlertWords);
        var playlists = AppServices.Playlists().ToList(); GuidePlaylist.ItemsSource = playlists; if (playlists.Count > 0) GuidePlaylist.SelectedIndex = 0;
        ReloadProfiles();
        LanSwitch.IsOn = AppServices.Settings.LanSync;
        VersionText.Text = "This is version " + CurrentVersion;
        AppServices.Lan.Changed += OnLanChanged;
        Unloaded += (_, _) => { AppServices.Lan.Changed -= OnLanChanged; AppServices.Lan.PairingOpen = false; };
        OnLanChanged();
        _quiet = false;
    }

    private void Say(string text, InfoBarSeverity severity = InfoBarSeverity.Success) { Message.Message = text; Message.Severity = severity; Message.IsOpen = true; }

    // ---------- Profiles ----------

    private List<Profile> _profiles = new();

    private void ReloadProfiles()
    {
        _profiles = AppServices.Profiles.All();
        ProfileList.ItemsSource = _profiles.Select(p => p.Name + (p.Kids ? "  (Kids)" : "") + (p.Pin is not null ? "  🔒 PIN" : "") + (p.Id == AppServices.Profile.Id ? "  ← in use" : "")).ToList();
        ProfileList.SelectedIndex = Math.Max(0, _profiles.FindIndex(p => p.Id == AppServices.Profile.Id));
    }

    private Profile? Selected => ProfileList.SelectedIndex >= 0 && ProfileList.SelectedIndex < _profiles.Count ? _profiles[ProfileList.SelectedIndex] : null;

    private async Task Safely(Func<Task> action)
    {
        try { await action(); }
        catch (Exception ex) when (ex is InvalidOperationException or ArgumentException or IOException) { Say(ex.Message, InfoBarSeverity.Error); }
    }

    private async void OnSwitch(object sender, RoutedEventArgs e) => await Safely(async () =>
    {
        if (AppServices.MainWindow is MainWindow w) { await w.ChooseProfileAsync(); ReloadProfiles(); w.ShowProfileChanged(); }
    });

    private async void OnAddProfile(object sender, RoutedEventArgs e) => await Safely(async () =>
    {
        var name = await Dialogs.AskAsync(XamlRoot, "New profile", "Name"); if (name is null) return;
        var kids = await Dialogs.ConfirmAsync(XamlRoot, "Kids profile?", "A Kids profile cannot open Settings or Connections and never shows locked folders.", "Yes, Kids");
        AppServices.Profiles.Add(name, kids); ReloadProfiles();
    });

    private async void OnSetPin(object sender, RoutedEventArgs e) => await Safely(async () =>
    {
        if (Selected is not { } p) return;
        // Changing a PIN needs the current one, so anyone at an unlocked computer cannot lock the owner out.
        if (p.Pin is not null && !await Dialogs.PinAsync(XamlRoot, "Current PIN", pin => AppServices.Profiles.CheckPin(p.Id, pin))) return;
        var pin = await Dialogs.AskAsync(XamlRoot, $"PIN for {p.Name}", "New PIN (4 to 8 digits)", secret: true); if (pin is null) return;
        if (!PinHash.IsValid(pin)) { Say("A PIN is 4 to 8 digits.", InfoBarSeverity.Warning); return; }
        AppServices.Profiles.SetPin(p.Id, pin); ReloadProfiles(); Say("PIN saved.");
    });

    private async void OnRemovePin(object sender, RoutedEventArgs e) => await Safely(async () =>
    {
        if (Selected is not { Pin: not null } p) return;
        if (!await Dialogs.PinAsync(XamlRoot, "Current PIN", pin => AppServices.Profiles.CheckPin(p.Id, pin))) return;
        AppServices.Profiles.SetPin(p.Id, null); ReloadProfiles();
    });

    private async void OnToggleKids(object sender, RoutedEventArgs e) => await Safely(async () =>
    {
        if (Selected is not { } p) return;
        if (p.Id == AppServices.Profile.Id && !p.Kids && !await Dialogs.ConfirmAsync(XamlRoot, "Make this a Kids profile?", "You are using it now. It will lose access to Settings and Connections until someone switches to a grown-up profile.", "Make Kids")) return;
        AppServices.Profiles.SetKids(p.Id, !p.Kids);
        if (p.Id == AppServices.Profile.Id) AppServices.SignIn(AppServices.Profiles.Find(p.Id)!);
        ReloadProfiles();
        if (AppServices.MainWindow is MainWindow w) w.ShowProfileChanged();
    });

    private async void OnRemoveProfile(object sender, RoutedEventArgs e) => await Safely(async () =>
    {
        if (Selected is not { } p) return;
        if (p.Id == AppServices.Profile.Id) { Say("Switch to another profile first.", InfoBarSeverity.Warning); return; }
        if (p.Pin is not null && !await Dialogs.PinAsync(XamlRoot, $"PIN for {p.Name}", pin => AppServices.Profiles.CheckPin(p.Id, pin))) return;
        if (!await Dialogs.ConfirmAsync(XamlRoot, $"Remove {p.Name}?", "Their favorites, history, collections and folder settings are deleted.", "Remove")) return;
        AppServices.Profiles.Remove(p.Id); ReloadProfiles();
    });

    // ---------- DNS ----------

    private void OnDnsChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_quiet) return;
        DnsUrl.Visibility = DnsBox.SelectedIndex == 4 ? Visibility.Visible : Visibility.Collapsed;
        if (DnsBox.SelectedIndex == 4) return;                                          // wait for the address
        AppServices.SaveSettings(AppServices.Settings with { Dns = DnsBox.SelectedIndex switch { 1 => "Cloudflare", 2 => "Google", 3 => "Quad9", _ => "" } });
        Say(DnsBox.SelectedIndex == 0 ? "Using the system's DNS." : "Looking up names through encrypted DNS.");
    }

    private void OnDnsUrl(object sender, RoutedEventArgs e)
    {
        if (DnsBox.SelectedIndex != 4) return;
        if (DnsProvider.Custom(DnsUrl.Text) is null) { Say("The address must start with https://", InfoBarSeverity.Warning); return; }
        AppServices.SaveSettings(AppServices.Settings with { Dns = DnsUrl.Text.Trim() });
        Say("Looking up names through your DNS server.");
    }

    // ---------- Subtitles and guide ----------

    private void OnSaveSubtitles(object sender, RoutedEventArgs e)
    {
        var language = LanguageBox.Text.Trim().ToLowerInvariant();
        if (language.Length < 2) { Say("Enter a language code such as en, fr or de.", InfoBarSeverity.Warning); return; }
        AppServices.SaveSettings(AppServices.Settings with { SubtitleLanguage = language, AutoSubtitles = AutoBox.IsChecked == true, OpenSubtitlesUser = string.IsNullOrWhiteSpace(OsUser.Text) ? null : OsUser.Text.Trim() });
        if (OsKey.Password.Length > 0) AppServices.Secrets.Set("opensubtitles:key", OsKey.Password); else AppServices.Secrets.Delete("opensubtitles:key");
        if (OsPass.Password.Length > 0) AppServices.Secrets.Set("opensubtitles:password", OsPass.Password); else AppServices.Secrets.Delete("opensubtitles:password");
        Say("Subtitle settings saved.");
    }

    private void OnGuidePlaylist(object sender, SelectionChangedEventArgs e)
    {
        GuideUrl.Text = GuidePlaylist.SelectedItem is Playlist p ? AppServices.Settings.GuideUrls.GetValueOrDefault(p.Id, "") : "";
    }

    private void OnSaveGuide(object sender, RoutedEventArgs e)
    {
        var urls = new Dictionary<string, string>(AppServices.Settings.GuideUrls);
        if (GuidePlaylist.SelectedItem is Playlist p)
        {
            var text = GuideUrl.Text.Trim();
            if (text.Length == 0) urls.Remove(p.Id);
            else if (!Uri.TryCreate(text, UriKind.Absolute, out var u) || u.Scheme is not ("http" or "https")) { Say("The guide address must start with http:// or https://", InfoBarSeverity.Warning); return; }
            else urls[p.Id] = text;
            AppServices.Forget(p.Id);                                                   // the next visit to the guide loads it afresh
        }
        var words = AlertBox.Text.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Where(w => w.Length > 1).Distinct(StringComparer.CurrentCultureIgnoreCase).ToList();
        AppServices.SaveSettings(AppServices.Settings with { GuideUrls = urls, AlertWords = words });
        Say("Guide settings saved.");
    }

    // ---------- Backup ----------

    private async void OnExport(object sender, RoutedEventArgs e) => await Safely(async () =>
    {
        var picker = new Windows.Storage.Pickers.FileSavePicker { SuggestedFileName = $"StreamSetu backup {DateTime.Now:yyyy-MM-dd}" };
        WinRT.Interop.InitializeWithWindow.Initialize(picker, AppServices.MainHandle);
        picker.FileTypeChoices.Add("StreamSetu backup", new List<string> { ".zip" });
        if (await picker.PickSaveFileAsync() is not { } file) return;
        await Task.Run(() => Backup.Export(AppServices.Store.Folder, file.Path));
        Say("Backup saved to " + file.Path);
    });

    private async void OnRestore(object sender, RoutedEventArgs e) => await Safely(async () =>
    {
        var picker = new Windows.Storage.Pickers.FileOpenPicker(); WinRT.Interop.InitializeWithWindow.Initialize(picker, AppServices.MainHandle); picker.FileTypeFilter.Add(".zip");
        if (await picker.PickSingleFileAsync() is not { } file) return;
        if (!await Dialogs.ConfirmAsync(XamlRoot, "Restore this backup?", "Everything now in StreamSetu is replaced by the backup. The current data is kept in a folder beside it, in case you change your mind. Passwords are not part of a backup.", "Restore")) return;
        var kept = await Task.Run(() => Backup.Restore(file.Path, AppServices.Store.Folder));
        await Dialogs.MessageAsync(XamlRoot, "Restored", $"Close StreamSetu and open it again to use the restored data.\n\nThe data it replaced is in:\n{kept}");
    });

    // ---------- Sync on this network ----------

    private void OnLanChanged()
    {
        var lan = AppServices.Lan;
        LanStatus.Text = lan.Status + (lan.LastSync is { } t ? $"   (last sync {t:HH:mm})" : "");
        PairedList.ItemsSource = lan.Paired.Select(p => p.Name).ToList();
        FoundList.ItemsSource = lan.Found.Select(f => f.Name + (lan.Paired.Any(p => p.Id == f.Id) ? "  (paired)" : "")).ToList();
    }

    private async void OnLanToggled(object sender, RoutedEventArgs e)
    {
        if (_quiet) return;
        AppServices.SaveSettings(AppServices.Settings with { LanSync = LanSwitch.IsOn });
        if (LanSwitch.IsOn) await AppServices.Lan.StartAsync(); else await AppServices.Lan.StopAsync();
        OnLanChanged();
    }

    private async void OnAddDevice(object sender, RoutedEventArgs e)
    {
        if (!AppServices.Lan.Enabled) { LanSwitch.IsOn = true; await AppServices.Lan.StartAsync(); }
        var open = PairPanel.Visibility != Visibility.Visible;
        PairPanel.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
        AppServices.Lan.PairingOpen = open;               // an unknown device may pair only while this screen is open
        AddDeviceButton.Content = open ? "Done" : "Add a device";
        OnLanChanged();
    }

    private async void OnConnectDevice(object sender, RoutedEventArgs e) => await Safely(async () =>
    {
        var found = AppServices.Lan.Found;
        if (FoundList.SelectedIndex < 0 || FoundList.SelectedIndex >= found.Count) { Say("Choose a device from the list.", InfoBarSeverity.Warning); return; }
        var outcome = await AppServices.Lan.SyncWithAsync(found[FoundList.SelectedIndex]);
        Say(outcome switch { LanOutcome.Synced s => $"{(s.Paired ? "Paired and synced with " : "Synced with ")}{s.Peer.Name}.", LanOutcome.Refused r => "Not paired: " + (r.Why == "not-paired" ? "the other device is not showing its Add a device screen." : r.Why), LanOutcome.Failed f => f.Why, _ => "" },
            outcome is LanOutcome.Synced ? InfoBarSeverity.Success : InfoBarSeverity.Warning);
        OnLanChanged();
    });

    private async void OnSyncNow(object sender, RoutedEventArgs e) => await Safely(async () =>
    {
        if (!AppServices.Lan.Enabled) { Say("Turn sync on first.", InfoBarSeverity.Warning); return; }
        await AppServices.Lan.SyncAllAsync(); OnLanChanged();
    });

    private async void OnForgetDevice(object sender, RoutedEventArgs e) => await Safely(async () =>
    {
        var paired = AppServices.Lan.Paired;
        if (PairedList.SelectedIndex < 0 || PairedList.SelectedIndex >= paired.Count) return;
        var p = paired[PairedList.SelectedIndex];
        if (await Dialogs.ConfirmAsync(XamlRoot, $"Forget {p.Name}?", "It stops syncing with this computer until you pair it again.", "Forget")) { AppServices.Lan.Forget(p.Id); OnLanChanged(); }
    });

    // ---------- Updates ----------

    /// <summary>The thumbprint of the certificate StreamSetu installers are signed with. Empty until a signing certificate is set up (Scripts\package.ps1 prints it): until then an update is downloaded and checked against its published checksum, but never run for you.</summary>
    private const string PinnedSignerThumbprint = "";

    private static Version CurrentVersion => System.Reflection.Assembly.GetEntryAssembly()?.GetName().Version ?? new Version(0, 1);
    private UpdateInfo? _update;

    private async void OnCheckUpdates(object sender, RoutedEventArgs e) => await Safely(async () =>
    {
        UpdateStatus.Text = "Checking…"; InstallButton.Visibility = Visibility.Collapsed;
        try
        {
            var json = await AppServices.Http.FetchTextAsync("https://api.github.com/repos/lokeshreddyveer/streamsetu/releases/latest", 2 * 1024 * 1024, headers: new Dictionary<string, string> { ["Accept"] = "application/vnd.github+json" });
            _update = Updates.Parse(json, CurrentVersion);
            UpdateStatus.Text = _update is null ? "You have the latest version." : $"Version {_update.Version} is available.";
            InstallButton.Visibility = _update is null ? Visibility.Collapsed : Visibility.Visible;
        }
        catch (Exception ex) when (ex is FetchRefusedException or InvalidOperationException) { UpdateStatus.Text = "Could not check: " + ex.Message; }
    });

    private async void OnInstallUpdate(object sender, RoutedEventArgs e) => await Safely(async () =>
    {
        if (_update is null) return;
        UpdateStatus.Text = "Downloading…";
        string path;
        try { path = await Updates.DownloadAsync(AppServices.Http, _update, Path.Combine(Path.GetTempPath(), "StreamSetu-update")); }
        catch (Exception ex) when (ex is FetchRefusedException or InvalidOperationException) { UpdateStatus.Text = ex.Message; return; }

        // The checksum matched what the release notes say. Running it also needs the signature to be ours.
        string? signer = null;
        try { signer = new X509Certificate2(X509Certificate.CreateFromSignedFile(path)).Thumbprint; } catch (Exception) { }
        if (PinnedSignerThumbprint.Length > 0 && string.Equals(signer, PinnedSignerThumbprint, StringComparison.OrdinalIgnoreCase))
        {
            UpdateStatus.Text = "Installing. StreamSetu will close and reopen.";
            Process.Start(new ProcessStartInfo(path, "/SILENT /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS") { UseShellExecute = true });
            Application.Current.Exit();
        }
        else
        {
            UpdateStatus.Text = "Downloaded and checked against its published checksum, but not run for you because its signature is not one StreamSetu knows. It is in the folder that just opened: run it yourself if you trust it.";
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
        }
    });
}
