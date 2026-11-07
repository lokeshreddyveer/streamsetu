using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using StreamSetu.Core;

namespace StreamSetu.App;

/// <summary>Several channels at once. Each tile is its own player in its own window, laid out by <see cref="MultiViewLayout"/>; one tile has the sound.</summary>
public sealed partial class MultiViewPage : Page
{
    private sealed class TileState(Playlist playlist, Item channel, IntPtr window, MpvBackend mpv, PlaybackSession session)
    {
        public Playlist Playlist { get; } = playlist; public Item Channel { get; } = channel; public IntPtr Window { get; } = window; public MpvBackend Mpv { get; } = mpv; public PlaybackSession Session { get; } = session;
        public string? Problem;
    }

    private readonly List<TileState> _tiles = new();
    private int _audio;
    private readonly DispatcherTimer _tick = new() { Interval = TimeSpan.FromSeconds(1) };

    public MultiViewPage()
    {
        InitializeComponent();
        _tick.Tick += (_, _) => PlaceTiles();
        Unloaded += (_, _) => CloseAll();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        // The single player's window is not needed here.
        if (AppServices.VideoHandle != IntPtr.Zero) VideoWindow.Hide(AppServices.VideoHandle);
        _tick.Start();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e) => CloseAll();

    private void CloseAll()
    {
        _tick.Stop();
        foreach (var t in _tiles.ToList()) Dispose(t);
        _tiles.Clear();
    }

    private static void Dispose(TileState t)
    {
        t.Session.Stop(); t.Mpv.Dispose(); VideoWindow.Destroy(t.Window);
    }

    private void OnAreaChanged(object sender, SizeChangedEventArgs e) => PlaceTiles();

    private void PlaceTiles()
    {
        if (XamlRoot is null) return;
        var origin = TilesArea.TransformToVisual(null).TransformPoint(new Windows.Foundation.Point(0, 0));
        var scale = XamlRoot.RasterizationScale;
        var tiles = MultiViewLayout.Tiles(_tiles.Count, (int)(TilesArea.ActualWidth * scale), (int)(TilesArea.ActualHeight * scale));
        for (int i = 0; i < _tiles.Count && i < tiles.Count; i++)
            VideoWindow.PlaceTile(_tiles[i].Window, (int)(origin.X * scale) + tiles[i].X, (int)(origin.Y * scale) + tiles[i].Y, tiles[i].Width, tiles[i].Height);
    }

    private void HideTiles() { foreach (var t in _tiles) VideoWindow.Hide(t.Window); }

    private void RefreshList()
    {
        TileList.ItemsSource = _tiles.Select((t, i) => $"{(i == _audio ? "🔊 " : "     ")}{t.Channel.Title}  ({t.Playlist.Name})" + (t.Problem is null ? "" : $"   — {t.Problem}")).ToList();
        TileList.SelectedIndex = Math.Min(Math.Max(TileList.SelectedIndex, 0), Math.Max(_tiles.Count - 1, 0));
    }

    private void ApplySound() { for (int i = 0; i < _tiles.Count; i++) _tiles[i].Mpv.SetMuted(i != _audio); }

    private async void OnAdd(object sender, RoutedEventArgs e)
    {
        if (_tiles.Count >= MultiViewLayout.MaxTiles) { Say($"Up to {MultiViewLayout.MaxTiles} channels at once.", InfoBarSeverity.Warning); return; }
        try
        {
            HideTiles();
            var pick = await PickChannelAsync();
            PlaceTiles();
            if (pick is null) return;
            await AddTileAsync(pick.Value.Playlist, pick.Value.Channel);
        }
        catch (Exception ex) when (ex is InvalidOperationException or FetchRefusedException) { Say(ex.Message, InfoBarSeverity.Error); }
    }

    private async Task<(Playlist Playlist, Item Channel)?> PickChannelAsync()
    {
        var playlists = AppServices.Playlists().Where(p => p.Kind != PlaylistKind.LocalFolder).ToList();
        if (playlists.Count == 0) { Say("Add a connection first.", InfoBarSeverity.Warning); return null; }
        var combo = new ComboBox { ItemsSource = playlists, DisplayMemberPath = "Name", SelectedIndex = 0, MinWidth = 320, Header = "Connection" };
        var search = new TextBox { PlaceholderText = "Search channels" };
        var list = new ListView { MaxHeight = 320, SelectionMode = ListViewSelectionMode.Single };
        List<Item> items = new();
        async Task LoadAsync()
        {
            if (combo.SelectedItem is not Playlist p) return;
            try { Busy.IsActive = true; items = (await AppServices.LoadAsync(p)).Library.Live; Filter(); }
            catch (Exception ex) when (ex is InvalidOperationException or FetchRefusedException) { items = new(); list.ItemsSource = new[] { ex.Message }; }
            finally { Busy.IsActive = false; }
        }
        void Filter() => list.ItemsSource = LibraryLoader.Search(items, search.Text).Take(300).Select(i => i.Title).ToList();
        combo.SelectionChanged += async (_, _) => await LoadAsync();
        search.TextChanged += (_, _) => Filter();
        await LoadAsync();
        var panel = new StackPanel { Spacing = 8, Children = { combo, search, list } };
        var dialog = new ContentDialog { Title = "Add a channel", Content = panel, PrimaryButtonText = "Add", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary, XamlRoot = XamlRoot };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || list.SelectedIndex < 0 || combo.SelectedItem is not Playlist chosen) return null;
        var title = list.SelectedItem as string;
        var channel = LibraryLoader.Search(items, search.Text).Take(300).ElementAtOrDefault(list.SelectedIndex);
        return channel is null || title is null ? null : (chosen, channel);
    }

    private async Task AddTileAsync(Playlist playlist, Item channel)
    {
        if (channel.Url is null) { Say("That channel has no address to play.", InfoBarSeverity.Warning); return; }
        var window = VideoWindow.Create(AppServices.MainHandle);
        var mpv = new MpvBackend(window);
        var tile = new TileState(playlist, channel, window, mpv, new PlaybackSession(mpv));
        if (AppServices.Resolver is { } resolver) mpv.Pinner = (url, ct) => Pinning.PinAsync(url, resolver, AppServices.Allow, ct);
        _tiles.Add(tile);
        tile.Session.Changed += () => DispatcherQueue.TryEnqueue(() => { tile.Problem = tile.Session.State == PlayState.Failed ? tile.Session.Error ?? "could not be played" : null; RefreshList(); });
        PlaceTiles(); ApplySound(); RefreshList();
        try { _ = tile.Session.PlayAsync(await AppServices.PlayUrlAsync(playlist, channel.Url), 0); }
        catch (InvalidOperationException ex) { tile.Problem = ex.Message; RefreshList(); }
    }

    private void OnAudio(object sender, RoutedEventArgs e) { if (TileList.SelectedIndex >= 0 && TileList.SelectedIndex < _tiles.Count) { _audio = TileList.SelectedIndex; ApplySound(); RefreshList(); } }

    private void OnRemove(object sender, RoutedEventArgs e)
    {
        var i = TileList.SelectedIndex;
        if (i < 0 || i >= _tiles.Count) return;
        Dispose(_tiles[i]); _tiles.RemoveAt(i);
        _audio = Math.Min(_audio, Math.Max(_tiles.Count - 1, 0));
        PlaceTiles(); ApplySound(); RefreshList();
    }

    private void Say(string text, InfoBarSeverity severity) { Message.Message = text; Message.Severity = severity; Message.IsOpen = true; }
}
