using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using StreamSetu.Core;

namespace StreamSetu.App;

public sealed partial class ConnectionsPage : Page
{
    // The order of the entries in the Type box.
    private static readonly PlaylistKind[] Kinds =
    {
        PlaylistKind.Xtream, PlaylistKind.M3u, PlaylistKind.M3u, PlaylistKind.HdHomeRun, PlaylistKind.TvHeadend, PlaylistKind.Enigma2,
        PlaylistKind.Jellyfin, PlaylistKind.Emby, PlaylistKind.Plex, PlaylistKind.WebDav, PlaylistKind.LocalFolder, PlaylistKind.Stalker,
    };

    public ConnectionsPage()
    {
        InitializeComponent();
        Reload();
        OnKindChanged(this, null!);
    }

    private PlaylistKind Kind => Kinds[Math.Max(0, KindBox.SelectedIndex)];
    private bool IsFile => KindBox.SelectedIndex == 2;
    private bool IsFolder => Kind == PlaylistKind.LocalFolder;
    private bool NeedsUser => Kind is PlaylistKind.Xtream or PlaylistKind.TvHeadend or PlaylistKind.WebDav or PlaylistKind.Jellyfin or PlaylistKind.Emby;
    private bool NeedsSecret => Kind is PlaylistKind.Xtream or PlaylistKind.TvHeadend or PlaylistKind.Jellyfin or PlaylistKind.Emby or PlaylistKind.Plex or PlaylistKind.WebDav or PlaylistKind.Stalker;

    private void Reload()
    {
        var all = AppServices.Store.Playlists();
        SavedList.ItemsSource = all;
        EmptyNote.Visibility = all.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnKindChanged(object sender, SelectionChangedEventArgs e)
    {
        if (UserBox is null || PassBox is null || Hint is null) return;              // fires once while the page is being built
        UserBox.Visibility = NeedsUser ? Visibility.Visible : Visibility.Collapsed;
        PassBox.Visibility = NeedsSecret ? Visibility.Visible : Visibility.Collapsed;
        BrowseButton.Visibility = IsFile || IsFolder ? Visibility.Visible : Visibility.Collapsed;
        (AddressBox.Header, AddressBox.PlaceholderText) = Kind switch
        {
            PlaylistKind.Xtream => ("Server address", "http://server.example:8080"),
            PlaylistKind.M3u when IsFile => ("Playlist file", @"C:\Users\me\Downloads\list.m3u"),
            PlaylistKind.M3u => ("Playlist link", "http://server.example/playlist.m3u"),
            PlaylistKind.HdHomeRun => ("Device address", "http://192.168.1.50"),
            PlaylistKind.TvHeadend => ("Server address", "http://192.168.1.20:9981"),
            PlaylistKind.Enigma2 => ("Receiver address", "http://192.168.1.30"),
            PlaylistKind.Jellyfin or PlaylistKind.Emby => ("Server address", "http://192.168.1.40:8096"),
            PlaylistKind.Plex => ("Server address", "http://192.168.1.60:32400"),
            PlaylistKind.WebDav => ("Folder address", "https://nas.example/remote.php/dav/files/me/Videos"),
            PlaylistKind.Stalker => ("Portal address", "http://portal.example:8080/c/"),
            _ => ("Folder", @"D:\Videos"),
        };
        PassBox.Header = Kind switch { PlaylistKind.Jellyfin or PlaylistKind.Emby => "API key (Dashboard, API keys)", PlaylistKind.Plex => "Plex token", PlaylistKind.Stalker => "MAC address (00:1A:79:12:34:56)", _ => "Password" };
        UserBox.Header = Kind switch { PlaylistKind.Jellyfin or PlaylistKind.Emby => "User name (which person's library to show)", _ => "User name" };
        Hint.Text = Kind switch
        {
            PlaylistKind.Jellyfin or PlaylistKind.Emby => "Create an API key in the server's dashboard and paste it as the password.",
            PlaylistKind.Plex => "Paste your X-Plex-Token. It is kept in Windows Credential Manager.",
            PlaylistKind.Stalker => "Use the MAC address your provider gave you for this portal. Channels and films are listed; the stream link is asked for each time you press play.",
            PlaylistKind.WebDav => "Leave the user name empty for a server that needs no login.",
            PlaylistKind.HdHomeRun or PlaylistKind.Enigma2 => "Live channels only.",
            PlaylistKind.LocalFolder => "Video files in this folder and its folders are listed. Folders and shortcuts that link back up are not followed.",
            _ => "",
        };
    }

    private void Say(string text, InfoBarSeverity severity) { Message.Message = text; Message.Severity = severity; Message.IsOpen = true; }

    private bool Filled()
    {
        if (string.IsNullOrWhiteSpace(AddressBox.Text)) { Say("Enter the address first.", InfoBarSeverity.Warning); return false; }
        if (Kind is PlaylistKind.Xtream or PlaylistKind.TvHeadend && (string.IsNullOrWhiteSpace(UserBox.Text) || PassBox.Password.Length == 0)) { Say("Enter the user name and password.", InfoBarSeverity.Warning); return false; }
        if (Kind is PlaylistKind.Jellyfin or PlaylistKind.Emby or PlaylistKind.Plex && PassBox.Password.Length == 0) { Say("Enter the key or token.", InfoBarSeverity.Warning); return false; }
        if (Kind == PlaylistKind.Stalker && !StalkerClient.IsMac(PassBox.Password)) { Say("The MAC address looks like 00:1A:79:12:34:56.", InfoBarSeverity.Warning); return false; }
        return true;
    }

    private async void OnBrowse(object sender, RoutedEventArgs e)
    {
        var hwnd = AppServices.MainHandle;
        if (IsFolder)
        {
            var picker = new Windows.Storage.Pickers.FolderPicker(); WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd); picker.FileTypeFilter.Add("*");
            if (await picker.PickSingleFolderAsync() is { } folder) AddressBox.Text = folder.Path;
        }
        else
        {
            var picker = new Windows.Storage.Pickers.FileOpenPicker(); WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);
            picker.FileTypeFilter.Add(".m3u"); picker.FileTypeFilter.Add(".m3u8");
            if (await picker.PickSingleFileAsync() is { } file) AddressBox.Text = file.Path;
        }
    }

    private Playlist Build(string id)
    {
        var address = IsFile || IsFolder ? AddressBox.Text.Trim() : Kind is PlaylistKind.M3u or PlaylistKind.WebDav ? AddressBox.Text.Trim() : Xtream.NormalizeHost(AddressBox.Text);
        var name = string.IsNullOrWhiteSpace(NameBox.Text) ? (IsFile || IsFolder ? Path.GetFileName(address.TrimEnd('\\', '/')) : Uri.TryCreate(Xtream.NormalizeHost(address), UriKind.Absolute, out var u) ? u.Host : address) : NameBox.Text.Trim();
        return new Playlist(id, name, Kind, address, NeedsUser && !string.IsNullOrWhiteSpace(UserBox.Text) ? UserBox.Text.Trim() : null, NeedsSecret ? LibraryLoader.SecretKey(id) : null);
    }

    private async void OnTest(object sender, RoutedEventArgs e)
    {
        if (!Filled()) return;
        SetBusy(true);
        try
        {
            // The host is allowed only because the person typed it here; saving keeps it allowed.
            var playlist = Build("test");
            AppServices.AllowHostOf(playlist);
            var loaded = await AppServices.Loader.LoadAsync(playlist, default, NeedsSecret ? PassBox.Password : null);
            var lib = loaded.Library;
            var counts = $"{lib.Live.Count:N0} channels, {lib.Movies.Count:N0} movies, {lib.Series.Count:N0} series";
            var until = loaded.Account?.Expires is { } d ? $" It runs until {d.LocalDateTime:d MMMM yyyy}." : "";
            var warning = loaded.Account?.Warning(DateTimeOffset.UtcNow);
            var empty = lib.Live.Count + lib.Movies.Count + lib.Series.Count == 0;
            Say(empty ? "It connected, but nothing was found in it." : $"It works: {counts}.{until}{(warning is null ? "" : " " + warning)}", empty || warning is not null ? InfoBarSeverity.Warning : InfoBarSeverity.Success);
        }
        catch (Exception ex) { Say(ex.Message, InfoBarSeverity.Error); }
        finally { SetBusy(false); }
    }

    private void OnSave(object sender, RoutedEventArgs e)
    {
        if (!Filled()) return;
        var id = Guid.NewGuid().ToString("N")[..12];
        var playlist = Build(id);
        if (NeedsSecret) AppServices.Secrets.Set(LibraryLoader.SecretKey(id), PassBox.Password);
        AppServices.Store.AddPlaylist(playlist);
        AppServices.AllowHostOf(playlist);
        NameBox.Text = AddressBox.Text = UserBox.Text = ""; PassBox.Password = "";
        Reload();
        Say($"Saved “{playlist.Name}”. Open Live TV, Movies or Series to see it.", InfoBarSeverity.Success);
    }

    private void OnRemove(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string id }) return;
        AppServices.Secrets.Delete(LibraryLoader.SecretKey(id));
        AppServices.Store.RemovePlaylist(id);
        AppServices.Forget(id);
        Reload();
    }

    private void SetBusy(bool busy) { Busy.IsActive = busy; TestButton.IsEnabled = SaveButton.IsEnabled = !busy; }
}
