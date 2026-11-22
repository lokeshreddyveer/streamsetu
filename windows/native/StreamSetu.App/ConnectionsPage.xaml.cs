using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using StreamSetu.Core;
using Windows.Storage.Streams;

namespace StreamSetu.App;

/// <summary>One way to connect on the welcome screen. Kinds are positions in the Type box; a tile with more than one lets the person pick between them on the form.</summary>
public sealed record ConnectionTile(string Title, string Subtitle, string Glyph, int[] Kinds, string[] KindNames);

public sealed partial class ConnectionsPage : Page
{
    // The order of the entries in the Type box.
    private static readonly PlaylistKind[] Kinds =
    {
        PlaylistKind.Xtream, PlaylistKind.M3u, PlaylistKind.M3u, PlaylistKind.HdHomeRun, PlaylistKind.TvHeadend, PlaylistKind.Enigma2,
        PlaylistKind.Jellyfin, PlaylistKind.Emby, PlaylistKind.Plex, PlaylistKind.WebDav, PlaylistKind.LocalFolder, PlaylistKind.Stalker, PlaylistKind.SingleStream,
    };

    // Every entry of the Type box is reachable from one of these tiles.
    private static readonly ConnectionTile[] Tiles =
    {
        new("Playlist link", "An M3U or M3U8 address", "\uE71B", new[] { 1 }, new[] { "M3U link" }),
        new("Xtream Codes", "Server, user name and password", "\uE8D7", new[] { 0 }, new[] { "Xtream Codes" }),
        new("Media server", "Plex, Jellyfin or Emby", "\uE8F1", new[] { 8, 6, 7 }, new[] { "Plex", "Jellyfin", "Emby" }),
        new("TV tuner or receiver", "HDHomeRun, TVHeadend or Enigma2", "\uE7F4", new[] { 3, 4, 5 }, new[] { "HDHomeRun", "TVHeadend", "Enigma2" }),
        new("Playlist file", "A file on this computer, a folder of videos or WebDAV", "\uE8B7", new[] { 2, 10, 9 }, new[] { "Playlist file", "Folder of videos", "WebDAV" }),
        new("Stalker portal", "Portal address and MAC", "\uE774", new[] { 11 }, new[] { "Stalker portal" }),
        new("Single stream", "One channel from a direct link", "\uE714", new[] { 12 }, new[] { "Single stream" }),
    };

    private readonly SetupDrafts _drafts = new(AppServices.Store);

    private ConnectionTile? _tile;          // the tile the form was opened from
    private bool _adding;                   // with saved connections, the types and the form show only after "Add a connection"
    private bool _hasSaved;
    private bool _narrow;
    private bool _quiet;                    // true while the page fills the member chooser itself
    private int _tileColumns;

    public ConnectionsPage()
    {
        InitializeComponent();
        BuildTiles();
        Reload();
        OnKindChanged(this, null!);
        LoadSymbol();
        Unloaded += (_, _) => SaveDraft();
        ShowResume();
    }

    private void BuildTiles()
    {
        foreach (var tile in Tiles)
        {
            var button = new PointerButton { Content = tile, Tag = tile, Style = (Style)Resources["TileButtonStyle"] };
            AutomationProperties.SetName(button, tile.Title);
            AutomationProperties.SetHelpText(button, tile.Subtitle);
            button.Click += OnTile;
            TileGrid.Children.Add(button);
        }
        LayoutTiles(2);
    }

    /// <summary>Two columns of tiles, three when there is room, one when the window is very narrow.</summary>
    private void LayoutTiles(int columns)
    {
        if (columns == _tileColumns) return;
        _tileColumns = columns;
        TileGrid.ColumnDefinitions.Clear();
        TileGrid.RowDefinitions.Clear();
        for (var c = 0; c < columns; c++) TileGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var r = 0; r < (TileGrid.Children.Count + columns - 1) / columns; r++) TileGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        for (var i = 0; i < TileGrid.Children.Count; i++)
        {
            var child = (FrameworkElement)TileGrid.Children[i];
            Grid.SetColumn(child, i % columns);
            Grid.SetRow(child, i / columns);
        }
    }

    /// <summary>The tiles and the type chooser follow the width of the setup column, so nothing is cut off from a small window to a very wide one.</summary>
    private void OnSetupSizeChanged(object sender, SizeChangedEventArgs e)
    {
        var width = e.NewSize.Width;
        LayoutTiles(width >= 760 ? 3 : width >= 420 ? 2 : 1);
        MemberChooser.MaxColumns = width >= 480 ? 3 : 1;
    }

    private void OnColumnsSizeChanged(object sender, SizeChangedEventArgs e)
    {
        var narrow = e.NewSize.Width < 900;
        if (narrow == _narrow) return;
        _narrow = narrow;
        Arrange();
    }

    /// <summary>Welcome (symbol and words beside the types) with no connection yet; otherwise the saved list, with the types and the form beside it while adding. A narrow window puts them one under the other.</summary>
    private void Arrange()
    {
        var setup = !_hasSaved || _adding;
        HeroPanel.Visibility = _hasSaved ? Visibility.Collapsed : Visibility.Visible;
        SavedPanel.Visibility = _hasSaved ? Visibility.Visible : Visibility.Collapsed;
        SetupPanel.Visibility = setup ? Visibility.Visible : Visibility.Collapsed;
        AddButton.Visibility = setup ? Visibility.Collapsed : Visibility.Visible;
        var stacked = _narrow || !setup;
        LeftColumn.Width = new GridLength(stacked ? 1 : 45, GridUnitType.Star);
        RightColumn.Width = stacked ? new GridLength(0) : new GridLength(55, GridUnitType.Star);
        Columns.ColumnSpacing = stacked ? 0 : 56;
        Columns.Padding = _narrow ? new Thickness(20, 24, 20, 32) : new Thickness(48, 40, 48, 48);
        Headline.FontSize = _narrow ? 34 : 48;
        Headline.LineHeight = _narrow ? 40 : 54;
        Grid.SetColumn(SetupPanel, stacked ? 0 : 1);
        Grid.SetRow(SetupPanel, stacked ? 1 : 0);
    }

    /// <summary>The brand symbol is read from the program's folder, which works the same with or without an app package.</summary>
    private async void LoadSymbol()
    {
        try
        {
            var path = Path.Combine(AppContext.BaseDirectory, "Assets", "BrandSymbol.png");
            if (!File.Exists(path)) return;
            var bytes = await File.ReadAllBytesAsync(path);                     // back on the screen's thread after this await
            using var stream = new InMemoryRandomAccessStream();
            await stream.WriteAsync(bytes.AsBuffer());
            stream.Seek(0);
            var image = new BitmapImage { DecodePixelWidth = 520 };
            await image.SetSourceAsync(stream);
            BrandImage.Source = image;
        }
        catch (Exception) { /* without the picture the welcome still reads well */ }
    }

    private void OnTile(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: ConnectionTile tile }) ShowForm(tile);
    }

    /// <summary>Opens the form for a tile by setting the Type box, which shows the right fields. What was typed before is kept.</summary>
    private void ShowForm(ConnectionTile tile)
    {
        _tile = tile;
        FormIcon.Glyph = tile.Glyph;
        FormTitle.Text = "Connect " + tile.Title;
        FormSubtitle.Text = tile.Subtitle;
        var member = Math.Max(0, Array.IndexOf(tile.Kinds, KindBox.SelectedIndex));     // coming back to the same tile keeps the type picked in it
        var several = tile.Kinds.Length > 1;
        _quiet = true;
        MemberChooser.ItemsSource = several ? tile.KindNames : null;
        MemberChooser.SelectedIndex = several ? member : -1;
        _quiet = false;
        MemberChooser.Visibility = several ? Visibility.Visible : Visibility.Collapsed;
        KindBox.SelectedIndex = tile.Kinds[member];
        Message.IsOpen = false;
        ChooserView.Visibility = Visibility.Collapsed;
        FormView.Visibility = Visibility.Visible;
        NameBox.Focus(FocusState.Programmatic);
    }

    private void OnMemberChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_quiet || _tile is null) return;
        var i = MemberChooser.SelectedIndex;
        if (i >= 0 && i < _tile.Kinds.Length) KindBox.SelectedIndex = _tile.Kinds[i];
    }

    private int IndexFor(PlaylistKind kind, string address)
        => kind == PlaylistKind.M3u && !address.StartsWith("http", StringComparison.OrdinalIgnoreCase) && address.Trim().Length > 0 ? 2 : Array.IndexOf(Kinds, kind);

    private void ShowResume() => ResumeButton.Visibility = _drafts.Load() is null ? Visibility.Collapsed : Visibility.Visible;

    /// <summary>What was typed so far (never a password, key or token), so "Continue previous setup" can bring it back.</summary>
    private void SaveDraft()
    {
        if (FormView.Visibility != Visibility.Visible) return;
        _drafts.Save(new SetupDraft(Kind, NameBox.Text, AddressBox.Text, UserBox.Text));
        ShowResume();
    }

    private ConnectionTile TileFor(int kindIndex) => Tiles.First(t => t.Kinds.Contains(kindIndex));

    private void OnResume(object sender, RoutedEventArgs e)
    {
        if (_drafts.Load() is not { } d) { ShowResume(); return; }
        var index = IndexFor(d.Kind, d.Address);
        KindBox.SelectedIndex = index;
        ShowForm(TileFor(index));
        NameBox.Text = d.Name; AddressBox.Text = d.Address; UserBox.Text = d.User ?? ""; PassBox.Password = "";
        if (NeedsSecret) Say("Enter the password or key again: it is never kept in a saved draft.", InfoBarSeverity.Informational);
    }

    private void OnPasteKey(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs e)
    {
        if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; OnPasteGo(sender, e); }
    }

    private void OnPasteGo(object sender, RoutedEventArgs e)
    {
        if (SetupPaste.Detect(PasteBox.Text) is not { } guess) { PasteNote.Text = string.IsNullOrWhiteSpace(PasteBox.Text) ? "Paste a link first, or choose how you connect below." : "That does not look like a link or a playlist file. Choose how you connect below."; return; }
        PasteNote.Text = "";
        var index = IndexFor(guess.Kind, guess.Address);
        KindBox.SelectedIndex = index;
        ShowForm(TileFor(index));
        AddressBox.Text = guess.Address; UserBox.Text = guess.User ?? ""; PassBox.Password = guess.Secret ?? "";
        PasteBox.Text = "";
    }

    private void ShowTypes()
    {
        ShowResume();
        FormView.Visibility = Visibility.Collapsed;
        ChooserView.Visibility = Visibility.Visible;
    }

    private void OnBackToTypes(object sender, RoutedEventArgs e)
    {
        SaveDraft();
        ShowTypes();
        var index = _tile is null ? -1 : Array.IndexOf(Tiles, _tile);
        if (index >= 0 && TileGrid.Children[index] is Control tile) tile.Focus(FocusState.Programmatic);
    }

    private void OnAddConnection(object sender, RoutedEventArgs e)
    {
        _adding = true;
        ShowTypes();
        Arrange();
        if (TileGrid.Children.FirstOrDefault() is Control first) first.Focus(FocusState.Programmatic);
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
        _hasSaved = all.Count > 0;
        Arrange();
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
            PlaylistKind.SingleStream => ("Stream link", "http://server.example/live/channel.ts"),
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
            PlaylistKind.SingleStream => "One live channel from a direct link (for example .ts, .m3u8 for one channel, rtmp or rtsp). Give it a name so you can find it in Live TV.",
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
        var address = IsFile || IsFolder ? AddressBox.Text.Trim() : Kind is PlaylistKind.M3u or PlaylistKind.WebDav or PlaylistKind.SingleStream ? AddressBox.Text.Trim() : Xtream.NormalizeHost(AddressBox.Text);
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
        _drafts.Clear(); ShowResume();
        AppServices.AllowHostOf(playlist);
        NameBox.Text = AddressBox.Text = UserBox.Text = ""; PassBox.Password = "";
        _adding = true;                                                     // the form stays open, so the message below it can be read
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
