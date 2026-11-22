using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Navigation;
using StreamSetu.Core;
using StreamSetu.Core.SmartMix;

namespace StreamSetu.App;

/// <summary>One line of a list.</summary>
public sealed record Row(Item Item, string Title, string Detail, string Mark, string? LogoUrl = null);

/// <summary>Live TV, Movies, Series, Favorites, Continue Watching, Unwatched, New and Collections: a list of titles from the chosen connection, with folders, search, filter and sort.</summary>
public sealed partial class BrowsePage : Page
{
    private string _mode = "live";
    private List<Playlist> _playlists = new();
    private Playlist? _playlist;
    private LoadedLibrary? _loaded;
    private List<Item> _all = new();
    private int _loadId;
    private ItemFilter _filter = new();
    private Guide? _guide;
    private bool _quiet;                                              // true while the page changes its own controls, so that does not count as the person choosing
    private readonly HashSet<string> _unlocked = new();               // folders opened with their PIN during this visit
    private int _pinTries;
    private int _rowsBuild;
    private int _foldersShown = 24;

    public BrowsePage() { InitializeComponent(); }

    private bool Kids => AppServices.Profile.Kids;
    private bool UsesFolders => _mode is "live" or "movie" or "series";
    private string Scope => (_playlist?.Id ?? "") + "|" + _mode;
    private string KeyOf(Item i) => AppServices.KeyOf(_playlist!, i);

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        _mode = e.Parameter as string ?? "live";
        Heading.Text = _mode switch
        {
            "live" => "Live TV", "movie" => "Movies", "series" => "Series", "favorites" => "Favorites", "continue" => "Continue Watching",
            "unwatched" => "Unwatched", "added" => "Added in the last 30 days", _ => "Collections",
        };
        FolderBox.Visibility = UsesFolders || _mode == "collections" ? Visibility.Visible : Visibility.Collapsed;
        FolderMenu.Visibility = (UsesFolders && !Kids) || _mode == "collections" ? Visibility.Visible : Visibility.Collapsed;
        FolderMenu.Content = _mode == "collections" ? "Collection" : "Folder";
        FilterButton.Visibility = _mode == "live" ? Visibility.Collapsed : Visibility.Visible;
        SortBox.Visibility = _mode == "live" ? Visibility.Collapsed : Visibility.Visible;
        ViewBox.Visibility = UsesFolders ? Visibility.Visible : Visibility.Collapsed;
        _quiet = true; ViewBox.SelectedIndex = AppServices.Settings.GridView ? 1 : 0; _quiet = false;

        _playlists = AppServices.Playlists().ToList();
        if (_playlists.Count == 0) { Say("Add a connection first (Connections, at the bottom of the menu).", InfoBarSeverity.Informational); return; }
        PlaylistBox.ItemsSource = _playlists;
        PlaylistBox.Visibility = _playlists.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        PlaylistBox.SelectedIndex = 0;      // choosing the first connection raises OnPlaylistChanged, which loads it
    }

    private async void OnPlaylistChanged(object sender, SelectionChangedEventArgs e)
    {
        if (PlaylistBox.SelectedItem is Playlist p) await LoadAsync(p);
    }

    private void Say(string text, InfoBarSeverity severity) { Message.Message = text; Message.Severity = severity; Message.IsOpen = true; }

    private async Task LoadAsync(Playlist playlist)
    {
        var mine = ++_loadId;                       // a slower, older load must not replace a newer choice
        _playlist = playlist; _guide = null; _unlocked.Clear(); Message.IsOpen = false; Busy.IsActive = true; ItemList.ItemsSource = null; CountText.Text = "";
        try
        {
            var loaded = await AppServices.LoadAsync(playlist);
            if (mine != _loadId) return;
            _loaded = loaded; _all = ItemsFor(loaded);
            BuildFolders();
            Apply();
            if (_all.Count == 0) Say(EmptyText(), InfoBarSeverity.Informational);
            if (_mode == "live") _ = LoadGuideAsync(playlist, mine);      // the list is usable at once; now and next fill in when the guide arrives
        }
        catch (Exception ex) { if (mine == _loadId) Say(ex.Message, InfoBarSeverity.Error); }
        finally { if (mine == _loadId) Busy.IsActive = false; }
    }

    private async Task LoadGuideAsync(Playlist playlist, int mine)
    {
        try
        {
            var guide = await AppServices.GuideAsync(playlist);
            if (mine != _loadId || guide is null) return;
            _guide = guide; Apply();
        }
        catch (Exception) { /* a missing or broken guide only means no now/next line */ }
    }

    private string EmptyText() => _mode switch
    {
        "favorites" => "Nothing here yet. Right-click a title and choose Add to favorites.",
        "continue" => "Nothing part-watched yet. Movies you stop part-way appear here.",
        "unwatched" => "Everything here has been watched.",
        "added" => "The provider has not added anything in the last 30 days, or does not say when it adds things.",
        "collections" => "No collections yet. Right-click a title and choose Add to collection.",
        _ => "This connection has nothing in this section.",
    };

    private List<Item> ItemsFor(LoadedLibrary loaded)
    {
        var lib = loaded.Library;
        var user = AppServices.User;
        IEnumerable<Item> titles() => lib.Movies.Concat(lib.Series);
        switch (_mode)
        {
            case "live": return lib.Live;
            case "movie": return lib.Movies;
            case "series": return lib.Series;
            case "favorites":
                var wanted = user.Favorites().ToHashSet();
                return lib.Live.Concat(titles()).Where(i => wanted.Contains(KeyOf(i))).ToList();
            case "unwatched": return SmartLists.Unwatched(titles(), KeyOf, user.Watched());
            case "added": return SmartLists.AddedWithin(titles(), DateTimeOffset.UtcNow, 30);
            case "collections": return lib.Live.Concat(titles()).ToList();
            default:
                var recent = user.RecentProgress().Select(p => p.Key).ToList();
                var movies = lib.Movies.ToDictionary(KeyOf);
                return recent.Where(movies.ContainsKey).Select(k => movies[k]).ToList();
        }
    }

    // ---------- Folders (and, in Collections, the collection chooser) ----------

    private void BuildFolders()
    {
        _quiet = true;
        try
        {
            if (_mode == "collections")
            {
                var cols = AppServices.Collections.All().Select(c => new FolderView(c.Id, c.Name, false)).ToList();
                FolderBox.ItemsSource = cols; FolderBox.SelectedIndex = cols.Count > 0 ? 0 : -1;
            }
            else if (UsesFolders)
            {
                var visible = AppServices.Folders.Visible(Scope, _all.Select(i => i.Group), Kids);
                FolderBox.ItemsSource = new[] { new FolderView("", "All folders", false) }.Concat(visible).ToList();
                FolderBox.SelectedIndex = 0;
            }
        }
        finally { _quiet = false; }
    }

    private FolderView? CurrentFolder => FolderBox.SelectedItem as FolderView;

    private async void OnFolderChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_quiet) return;
        if (UsesFolders && CurrentFolder is { Locked: true } f && !_unlocked.Contains(f.Name))
        {
            if (!await TryUnlockAsync(f)) { _quiet = true; FolderBox.SelectedIndex = 0; _quiet = false; return; }
        }
        Apply();
    }

    /// <summary>Asks for the folder's PIN; on success the folder stays open for this visit.</summary>
    private async Task<bool> TryUnlockAsync(FolderView f)
    {
        var ok = await Dialogs.PinAsync(XamlRoot, $"“{f.Display}” is locked", pin =>
        {
            if (++_pinTries > 5) { _pinTries = 0; return PinResult.Locked; }
            return AppServices.Folders.Unlock(Scope, f.Name, pin) ? PinResult.Ok : PinResult.Wrong;
        });
        if (!ok) return false;
        _pinTries = 0; _unlocked.Add(f.Name);
        return true;
    }

    private async void OnFolderMenu(object sender, RoutedEventArgs e)
    {
        var flyout = new MenuFlyout();
        void Add(string text, Func<Task> action) { var item = new MenuFlyoutItem { Text = text }; item.Click += async (_, _) => { try { await action(); } catch (Exception ex) { Say(ex.Message, InfoBarSeverity.Error); } }; flyout.Items.Add(item); }

        if (_mode == "collections")
        {
            Add("New collection…", async () => { var n = await Dialogs.AskAsync(XamlRoot, "New collection", "Name"); if (n is not null) { AppServices.Collections.Create(n); BuildFolders(); Apply(); } });
            if (CurrentFolder is { } c)
            {
                Add("Rename…", async () => { var n = await Dialogs.AskAsync(XamlRoot, "Rename collection", "Name", initial: c.Display); if (n is not null) { AppServices.Collections.Rename(c.Name, n); BuildFolders(); Apply(); } });
                Add("Delete", async () => { if (await Dialogs.ConfirmAsync(XamlRoot, "Delete this collection?", $"“{c.Display}” is deleted. The titles in it are not.", "Delete")) { AppServices.Collections.Delete(c.Name); BuildFolders(); Apply(); } });
            }
            flyout.ShowAt(FolderMenu);
            return;
        }

        if (CurrentFolder is not { Name.Length: > 0 } folder) { Say("Choose a folder first.", InfoBarSeverity.Informational); return; }
        var groups = _all.Select(i => i.Group).Distinct().ToList();
        Add("Rename…", async () => { var n = await Dialogs.AskAsync(XamlRoot, "Rename folder", "Name", initial: folder.Display); if (n is not null) { AppServices.Folders.Rename(Scope, folder.Name, n); BuildFolders(); Apply(); } });
        Add("Hide", () => { AppServices.HideEverywhere(_mode, folder.Name); BuildFolders(); Apply(); return Task.CompletedTask; });
        Add("Move up", () => { AppServices.Folders.MoveUp(Scope, groups, folder.Name); BuildFolders(); return Task.CompletedTask; });
        Add("Move down", () => { AppServices.Folders.MoveDown(Scope, groups, folder.Name); BuildFolders(); return Task.CompletedTask; });
        if (folder.Locked)
            Add("Remove the PIN lock…", async () =>
            {
                if (!await Dialogs.PinAsync(XamlRoot, "Current PIN", pin => AppServices.Folders.Unlock(Scope, folder.Name, pin) ? PinResult.Ok : PinResult.Wrong)) return;
                AppServices.Folders.SetLock(Scope, folder.Name, null); BuildFolders(); Apply();
            });
        else
            Add("Lock with a PIN…", async () =>
            {
                var pin = await Dialogs.AskAsync(XamlRoot, "Lock this folder", "PIN (4 to 8 digits)", secret: true);
                if (pin is null) return;
                if (!PinHash.IsValid(pin)) { Say("A PIN is 4 to 8 digits.", InfoBarSeverity.Warning); return; }
                AppServices.LockEverywhere(_mode, folder.Name, pin); AppServices.Mix.Purge(); BuildFolders(); Apply();
            });
        flyout.ShowAt(FolderMenu);
        await Task.CompletedTask;
    }

    // ---------- Search, filter, sort ----------

    private void OnSearchChanged(object sender, TextChangedEventArgs e) => Apply();

    private void OnViewChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_quiet || _playlist is null) return;
        AppServices.SaveSettings(AppServices.Settings with { GridView = ViewBox.SelectedIndex == 1 });
        Apply();
    }
    private void OnSortChanged(object sender, SelectionChangedEventArgs e) { if (!_quiet && ItemList is not null) Apply(); }

    private async void OnFilterClick(object sender, RoutedEventArgs e)
    {
        ComboBox Make(string header, params string[] options) { var c = new ComboBox { Header = header, MinWidth = 260, ItemsSource = options, SelectedIndex = 0 }; return c; }
        var languages = new[] { "Any" }.Concat(_all.Select(i => Tags.Of(i.Title).Language).Where(l => l is not null).Select(l => l!).Distinct().OrderBy(l => l)).ToArray();
        var language = Make("Language", languages); var quality = Make("Quality", "Any", "720p or better", "1080p or better", "4K");
        var rating = Make("Rating", "Any", "3 stars or more", "4 stars or more"); var decade = Make("Decade", new[] { "Any" }.Concat(Enumerable.Range(0, 8).Select(i => $"{2020 - i * 10}s")).ToArray());
        var status = Make("Watch status", "Any", "Unwatched", "Started");
        language.SelectedItem = _filter.Language ?? "Any"; if (language.SelectedItem is null) language.SelectedIndex = 0;
        quality.SelectedIndex = _filter.MinQuality switch { Quality.Hd720 => 1, Quality.Hd1080 => 2, Quality.Uhd4K => 3, _ => 0 };
        rating.SelectedIndex = _filter.MinRating >= 4 ? 2 : _filter.MinRating >= 3 ? 1 : 0;
        decade.SelectedIndex = _filter.Decade is { } d ? Math.Max(0, (2020 - d) / 10 + 1) : 0;
        status.SelectedIndex = (int)_filter.Status;
        var panel = new StackPanel { Spacing = 12 }; foreach (var c in new[] { language, quality, rating, decade, status }) panel.Children.Add(c);
        var dialog = new ContentDialog { Title = "Filter", Content = panel, PrimaryButtonText = "Apply", SecondaryButtonText = "Clear", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary, XamlRoot = XamlRoot };
        var result = await dialog.ShowAsync();
        if (result == ContentDialogResult.Secondary) _filter = new ItemFilter();
        else if (result == ContentDialogResult.Primary)
            _filter = new ItemFilter(
                language.SelectedIndex > 0 ? (string)language.SelectedItem : null,
                quality.SelectedIndex switch { 1 => Quality.Hd720, 2 => Quality.Hd1080, 3 => Quality.Uhd4K, _ => Quality.Unknown },
                rating.SelectedIndex switch { 1 => 3, 2 => 4, _ => 0 },
                decade.SelectedIndex > 0 ? 2020 - (decade.SelectedIndex - 1) * 10 : null,
                (WatchStatus)status.SelectedIndex);
        else return;
        FilterButton.Content = _filter == new ItemFilter() ? "Filter" : "Filter ●";
        Apply();
    }

    private void Apply()
    {
        if (_playlist is null) return;
        if (ShowFolderRows)
        {
            ItemList.Visibility = Visibility.Collapsed; FolderRows.Visibility = Visibility.Visible; CountText.Text = "";
            _ = BuildFolderRowsAsync();
            return;
        }
        ItemList.Visibility = Visibility.Visible; FolderRows.Visibility = Visibility.Collapsed;
        var user = AppServices.User; var watched = user.Watched(); var progress = user.RecentProgress().Select(p => p.Key).ToHashSet();
        IEnumerable<Item> items = _all;

        if (_mode == "collections")
        {
            var keys = CurrentFolder is { } c ? AppServices.Collections.All().FirstOrDefault(x => x.Id == c.Name)?.Keys.ToHashSet() ?? new() : new HashSet<string>();
            items = items.Where(i => keys.Contains(KeyOf(i)));
        }
        else if (UsesFolders)
        {
            // Hidden folders (and locked ones not yet opened) stay out of "All folders"; choosing a folder shows just that one.
            var visible = AppServices.Folders.Visible(Scope, _all.Select(i => i.Group), Kids).Where(f => !f.Locked || _unlocked.Contains(f.Name)).Select(f => f.Name).ToHashSet();
            items = CurrentFolder is { Name.Length: > 0 } f2 ? items.Where(i => i.Group == f2.Name) : items.Where(i => visible.Contains(i.Group));
        }

        items = LibraryLoader.Search(items, SearchBox.Text ?? "");
        if (_mode != "live") items = _filter.Apply(items, KeyOf, watched, progress.Contains);
        items = (_mode == "live" ? 0 : SortBox.SelectedIndex) switch
        {
            1 => items.OrderBy(i => i.Title, StringComparer.CurrentCultureIgnoreCase),
            2 => items.OrderByDescending(i => i.Added),
            3 => items.OrderByDescending(i => i.Rating),
            4 => items.OrderByDescending(i => i.Year),
            _ => items,
        };

        var now = DateTimeOffset.UtcNow;
        var rows = items.Take(20_000).Select(i =>
        {
            string detail;
            if (i.Kind == Kind.Live)
            {
                var on = _guide?.Now(i.EpgId, now); var next = _guide?.Next(i.EpgId, now);
                detail = on is null ? i.Group : $"{i.Group}  ·  Now: {on.Title}" + (next is null ? "" : $"  ·  Next: {next.Title}");
            }
            else detail = string.Join("  ·  ", new[] { i.Group, i.Year?.ToString(), i.Rating is { } r ? new string('★', (int)Math.Round(r)) : null }.Where(s => !string.IsNullOrEmpty(s)));
            return new Row(i, i.Title, detail, watched.Contains(KeyOf(i)) ? "✓" : "", i.Logo);
        }).ToList();
        ItemList.ItemsSource = rows;
        CountText.Text = rows.Count == 0 ? "" : rows.Count == 20_000 ? "Showing the first 20,000. Use search or a folder to narrow down." : $"{rows.Count:N0} titles";
    }

    // ---------- Opening and playing ----------

    private async void OnItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not Row { Item: var item } || _playlist is null || _loaded is null) return;
        await ItemOpener.OpenAsync(Frame, XamlRoot, _playlist, _loaded, item, b => Busy.IsActive = b, Say);
    }

    // ---------- Folder rows ----------

    /// <summary>One row per folder, unless the person is searching, filtering, sorting, looking at one folder, or chose Grid.</summary>
    private bool ShowFolderRows => UsesFolders && ViewBox.SelectedIndex == 0 && _all.Count > 0 && CurrentFolder is not { Name.Length: > 0 }
        && string.IsNullOrWhiteSpace(SearchBox.Text) && _filter == new ItemFilter() && SortBox.SelectedIndex == 0;

    private async Task BuildFolderRowsAsync()
    {
        var mine = ++_rowsBuild;
        var playlist = _playlist!;
        var kind = _mode switch { "movie" => Kind.Movie, "series" => Kind.Series, _ => Kind.Live };
        try
        {
            var folders = AppServices.Folders.Visible(Scope, _all.Select(i => i.Group), Kids);
            var shown = folders.Take(_foldersShown).ToList();
            var ours = _all.Select(i => new Copy(playlist.Id, i)).ToList();
            var counts = Privacy.FolderCounts(AppServices.PrivacyNow(_unlocked), kind, ours).ToDictionary(c => c.Name, c => c.Count);
            var rows = new Dictionary<string, List<Copy>>();
            if (kind != Kind.Live)
            {
                var open = shown.Where(f => !f.Locked).Select(f => f.Name).ToList();                         // a folder opened with its PIN is shown by choosing it, not on a row
                var copies = await AppServices.AllCopiesAsync();
                if (mine != _rowsBuild) return;
                var mix = AppServices.Mix.Open(AppServices.DayKey());
                var inputs = AppServices.BuildHomeInputs(copies, new TrendingInput(), _unlocked);
                rows = await Task.Run(() => HomeBuilder.FolderRows(inputs, mix.State, SmartMixStore.ProfileKey, mix.Refresh, kind, open));
            }
            if (mine != _rowsBuild) return;

            FolderRowsPanel.Children.Clear();
            foreach (var f in shown)
            {
                var locked = f.Locked;
                var block = new StackPanel { Spacing = 6 };
                block.Children.Add(Tiles.FolderHeader(f.Display, locked && !_unlocked.Contains(f.Name) ? null : counts.GetValueOrDefault(f.Name), locked && !_unlocked.Contains(f.Name), () => OpenFolder(f)));
                if (!locked)
                {
                    IEnumerable<Copy> tiles = kind == Kind.Live ? _all.Where(i => i.Group == f.Name).Take(12).Select(i => new Copy(playlist.Id, i)) : rows.GetValueOrDefault(f.Name) ?? new List<Copy>();
                    if (tiles.Any()) block.Children.Add(Tiles.Strip(tiles, OpenCopy, kind == Kind.Live ? 96 : 128));
                }
                FolderRowsPanel.Children.Add(block);
            }
            if (folders.Count > shown.Count)
            {
                var more = new Button { Content = "Show more folders" };
                more.Click += (_, _) => { _foldersShown += 24; Apply(); };
                FolderRowsPanel.Children.Add(more);
            }
        }
        catch (Exception ex) { if (mine == _rowsBuild) Say(ex.Message, InfoBarSeverity.Error); }
    }

    private async void OpenFolder(FolderView f)
    {
        if (f.Locked && !_unlocked.Contains(f.Name) && !await TryUnlockAsync(f)) return;
        if (FolderBox.ItemsSource is IEnumerable<FolderView> list && list.FirstOrDefault(x => x.Name == f.Name) is { } match) FolderBox.SelectedItem = match;
    }

    /// <summary>The other copies of this title (another language, quality or connection), without anything from a locked, hidden or adult-blocked folder.</summary>
    private async Task ShowVersionsAsync(Item item)
    {
        try
        {
            var copies = await AppServices.AllCopiesAsync();
            var snap = Privacy.Snapshot(AppServices.PrivacyNow(_unlocked), Surface.Search, copies);
            var names = AppServices.Playlists().ToDictionary(p => p.Id, p => p.Name);
            var language = AppServices.Settings.PreferredLanguage;
            var ctx = new CanonicalPick.Context(language, AppServices.SourceRank());
            var versions = OtherVersions.For(snap, new Copy(_playlist!.Id, item), copies, ctx);
            if (versions.Count == 0) { Say("There are no other versions of this title.", InfoBarSeverity.Informational); return; }
            var labels = versions.Select(v => string.Join("  ·  ", new[] { v.Language ?? "Original", OtherVersions.QualityLabel(v.QualityRank), names.GetValueOrDefault(v.Copy.PlaylistId) ?? "" }.Where(x => x.Length > 0))).ToList();
            var list = new ListView { SelectionMode = ListViewSelectionMode.Single, MaxHeight = 360, ItemsSource = labels, SelectedIndex = 0 };
            var dialog = new ContentDialog { Title = item.Title, Content = list, PrimaryButtonText = "Open", CloseButtonText = "Close", DefaultButton = ContentDialogButton.Primary, XamlRoot = XamlRoot };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary || list.SelectedIndex < 0) return;
            OpenCopy(versions[list.SelectedIndex].Copy);
        }
        catch (Exception ex) { Say(ex.Message, InfoBarSeverity.Error); }
    }

    private async Task ShowCastAsync(Item item)
    {
        try { await CastDialog.ShowAsync(XamlRoot, new Copy(_playlist!.Id, item), await AppServices.AllCopiesAsync(), OpenCopy); }
        catch (Exception ex) { Say(ex.Message, InfoBarSeverity.Error); }
    }

    private async void OpenCopy(Copy copy)
    {
        try
        {
            var playlist = AppServices.Playlists().FirstOrDefault(p => p.Id == copy.PlaylistId);
            if (playlist is null) return;
            var loaded = await AppServices.LoadAsync(playlist);
            await ItemOpener.OpenAsync(Frame, XamlRoot, playlist, loaded, copy.Item, b => Busy.IsActive = b, Say);
        }
        catch (Exception ex) { Say(ex.Message, InfoBarSeverity.Error); }
    }

    private void OnRightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if ((e.OriginalSource as FrameworkElement)?.DataContext is not Row { Item: var item } || _playlist is null) return;
        var key = KeyOf(item); var user = AppServices.User;
        var flyout = new MenuFlyout();
        MenuFlyoutItem Add(string text, Action action) { var m = new MenuFlyoutItem { Text = text }; m.Click += (_, _) => { try { action(); } catch (Exception ex) { Say(ex.Message, InfoBarSeverity.Error); } }; flyout.Items.Add(m); return m; }

        Add(user.IsFavorite(key) ? "Remove from favorites" : "Add to favorites", () => { user.ToggleFavorite(key); if (_mode == "favorites") { _all = ItemsFor(_loaded!); Apply(); } });
        if (item.Url is not null)
        {
            var entry = new PlayQueue.Entry(key, item.Title, item.Url);
            Add("Play next", () => AppServices.Queue.PlayNext(entry));
            Add("Add to queue", () => AppServices.Queue.Add(entry));
        }
        var sub = new MenuFlyoutSubItem { Text = "Add to collection" };
        foreach (var c in AppServices.Collections.All()) { var id = c.Id; var m = new MenuFlyoutItem { Text = c.Name }; m.Click += (_, _) => AppServices.Collections.Add(id, key); sub.Items.Add(m); }
        var create = new MenuFlyoutItem { Text = "New collection…" };
        create.Click += async (_, _) =>
        {
            try { var n = await Dialogs.AskAsync(XamlRoot, "New collection", "Name"); if (n is not null) AppServices.Collections.Add(AppServices.Collections.Create(n).Id, key); }
            catch (Exception ex) { Say(ex.Message, InfoBarSeverity.Error); }
        };
        sub.Items.Add(create); flyout.Items.Add(sub);
        if (item.Kind != Kind.Live) Add("Cast…", () => _ = ShowCastAsync(item));
        if (item.Kind != Kind.Live) Add("Other languages and versions…", () => _ = ShowVersionsAsync(item));
        if (item.Kind != Kind.Live)
        {
            var isWatched = user.Watched().Contains(key);
            Add(isWatched ? "Mark as unwatched" : "Mark as watched", () => { if (isWatched) user.MarkUnwatched(key); else user.MarkWatched(key); Apply(); });
        }
        if (_mode == "collections" && CurrentFolder is { } col) Add("Remove from this collection", () => { AppServices.Collections.Remove(col.Name, key); Apply(); });
        flyout.ShowAt(ItemList, e.GetPosition(ItemList));
    }
}
