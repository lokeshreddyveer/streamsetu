using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Navigation;
using StreamSetu.Core;

namespace StreamSetu.App;

public sealed partial class PlayerPage : Page
{
    private PlayRequest? _request;
    private PlaybackSession? _session;
    private readonly DispatcherTimer _tick = new() { Interval = TimeSpan.FromSeconds(1) };
    private int _seconds;
    private bool _paused;
    private bool _dragging;
    private double _lastPosition, _lastDuration;
    private readonly Queue<Failover.Alternative> _alternatives = new();
    private bool _alternativesLoaded;
    private readonly List<string> _tempFiles = new();
    private bool _autoSubtitlesTried;
    private bool _finishing;
    private bool _mini;
    private Windows.Graphics.SizeInt32 _restoreSize;
    private List<Chapter> _chapters = new();
    private SkipOffer? _offer;

    public PlayerPage()
    {
        InitializeComponent();
        _tick.Tick += OnTick;
        // A slider marks pointer events handled, so this is registered to hear them anyway: while it is held, the ticking clock must not move it.
        SeekBar.AddHandler(PointerPressedEvent, new PointerEventHandler((_, _) => _dragging = true), true);
        Unloaded += (_, _) => Leave();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        if (e.Parameter is not PlayRequest request) return;
        _request = request;
        TitleText.Text = request.Title;
        SubText.Text = request.Playlist.Name;
        SeekBar.IsEnabled = BackTen.IsEnabled = ForwardTen.IsEnabled = !request.Live;
        TimeText.Text = request.Live ? "Live" : "";
        _session = AppServices.EnsurePlayer();
        _session.Changed += OnSessionChanged;
        PlaceVideo();
        _tick.Start();
        _ = _session.PlayAsync(request.Url, request.StartAt);
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e) => Leave();

    /// <summary>Stops, hides the video window and saves the place. Safe to call more than once.</summary>
    private void Leave()
    {
        _tick.Stop();
        if (_session is null) return;
        if (_mini) SetMini(false);
        SavePlace();
        _session.Changed -= OnSessionChanged;
        _session.Stop();
        _session = null;
        AppServices.Sleep.Cancel();
        foreach (var f in _tempFiles) try { File.Delete(f); } catch (IOException) { }
        _tempFiles.Clear();
        if (AppServices.VideoHandle != IntPtr.Zero) VideoWindow.Hide(AppServices.VideoHandle);
        var window = AppServices.MainWindow.AppWindow;
        if (window.Presenter.Kind == AppWindowPresenterKind.FullScreen) window.SetPresenter(AppWindowPresenterKind.Default);
    }

    // Changes can arrive from a background thread; the screen is only touched on its own thread.
    private void OnSessionChanged() => DispatcherQueue.TryEnqueue(async () =>
    {
        if (_session is null) return;
        Busy.IsActive = _session.State == PlayState.Loading;
        if (_session.State == PlayState.Failed)
        {
            // A live channel that stops working tries the same channel in the person's other connections before giving up.
            if (_request is { Live: true, Channel: not null } && await TryAlternativeAsync()) return;
            Message.Message = _session.Error ?? "This stream could not be played."; Message.IsOpen = true;
        }
        else Message.IsOpen = false;
        if (_session.State == PlayState.Playing)
        {
            _paused = false; PauseButton.Content = "Pause";
            if (_request is { Live: false } && AppServices.Settings.AutoSubtitles && !_autoSubtitlesTried) { _autoSubtitlesTried = true; _ = AutoSubtitlesAsync(); }
        }
    });

    private async Task<bool> TryAlternativeAsync()
    {
        if (!_alternativesLoaded)
        {
            _alternativesLoaded = true;
            var others = new List<(Playlist, IEnumerable<Item>)>();
            foreach (var p in AppServices.Playlists().Where(p => p.Id != _request!.Playlist.Id))
                try { others.Add((p, (await AppServices.LoadAsync(p)).Library.Live)); } catch (Exception) { /* a connection that will not load offers nothing */ }
            foreach (var a in Failover.Alternatives(_request!.Playlist, _request.Channel!, others)) _alternatives.Enqueue(a);
        }
        if (_alternatives.Count == 0 || _session is null) return false;
        var next = _alternatives.Dequeue();
        SubText.Text = $"{_request!.Title} did not play here: trying it from {next.Playlist.Name}";
        try { _ = _session.PlayAsync(await AppServices.PlayUrlAsync(next.Playlist, next.Channel.Url!), 0); } catch (InvalidOperationException) { return await TryAlternativeAsync(); }
        return true;
    }

    private void OnVideoAreaChanged(object sender, SizeChangedEventArgs e) => PlaceVideo();

    /// <summary>The video window is a real window over the page, so it is moved to exactly cover the video area, in pixels.</summary>
    private void PlaceVideo()
    {
        if (XamlRoot is null || AppServices.VideoHandle == IntPtr.Zero) return;
        var origin = VideoArea.TransformToVisual(null).TransformPoint(new Windows.Foundation.Point(0, 0));
        var scale = XamlRoot.RasterizationScale;
        VideoWindow.Place(AppServices.VideoHandle, (int)(origin.X * scale), (int)(origin.Y * scale), (int)(VideoArea.ActualWidth * scale), (int)(VideoArea.ActualHeight * scale));
    }

    private void OnTick(object? sender, object e)
    {
        PlaceVideo();                                   // the menu pane opening or closing moves the area without resizing it; this also puts the window back after a dialog
        var mpv = AppServices.Mpv;
        if (mpv is null || _request is null || _session is null) return;

        if (AppServices.Sleep.Due()) { OnBack(this, new RoutedEventArgs()); return; }
        SleepButton.Content = AppServices.Sleep.Remaining is { } left ? $"Sleep in {(int)Math.Ceiling(left.TotalMinutes)} min" : "Sleep timer";
        if (_session.State != PlayState.Playing) return;

        if (mpv.IsIdle) { _ = FinishedAsync(); return; }           // the stream ended
        if (_request.Live) return;
        double position = mpv.Position, duration = mpv.Duration;
        if (_seconds % 5 == 0 || _chapters.Count == 0 && _seconds % 2 == 0) _chapters = mpv.Chapters();
        _offer = SkipMarkers.Offer(_chapters, position, duration);
        SkipButton.Visibility = _offer is null || _mini ? Visibility.Collapsed : Visibility.Visible;
        if (_offer is not null) SkipButton.Content = _offer.Label;
        if (duration > 0) { _lastPosition = position; _lastDuration = duration; }
        if (duration > 0 && !_dragging) { SeekBar.Maximum = duration; SeekBar.Value = position; }
        TimeText.Text = $"{Clock(position)} / {Clock(duration)}";
        if (++_seconds % 5 == 0) SavePlace();
    }

    /// <summary>The stream ended: a title that played to the end is marked watched, and the queue goes on to the next entry.</summary>
    private async Task FinishedAsync()
    {
        if (_finishing || _request is null) return;
        _finishing = true;
        try
        {
            if (!_request.Live && _lastDuration > 0) AppServices.User.SaveProgress(_request.Key, _lastPosition, _lastDuration);     // near the end counts as watched
            if (AppServices.Queue.Next() is { } next)
            {
                _request = _request with { Key = next.Key, Title = next.Title, Url = next.Url, StartAt = AppServices.User.ProgressOf(next.Key)?.Position ?? 0, Live = false, Channel = null };
                TitleText.Text = next.Title; _lastDuration = 0; _autoSubtitlesTried = false;
                if (_session is not null) await _session.PlayAsync(await AppServices.PlayUrlForKeyAsync(next.Key, next.Url), _request.StartAt);
            }
            else if (!_request.Live) OnBack(this, new RoutedEventArgs());
        }
        finally { _finishing = false; }
    }

    private void SavePlace()
    {
        var mpv = AppServices.Mpv;
        if (mpv is null || _request is null || _request.Live) return;
        double duration = mpv.Duration;
        if (duration > 0) AppServices.User.SaveProgress(_request.Key, mpv.Position, duration);
    }

    private static string Clock(double seconds)
    {
        var t = TimeSpan.FromSeconds(Math.Max(0, seconds));
        return t.TotalHours >= 1 ? $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}" : $"{t.Minutes}:{t.Seconds:00}";
    }

    private void OnBack(object sender, RoutedEventArgs e) { Leave(); if (Frame.CanGoBack) Frame.GoBack(); }

    private void OnPause(object sender, RoutedEventArgs e)
    {
        _paused = !_paused;
        AppServices.Mpv?.SetPaused(_paused);
        PauseButton.Content = PipPause.Content = _paused ? "Play" : "Pause";
    }

    private void OnBackTen(object sender, RoutedEventArgs e) => AppServices.Mpv?.SeekBy(-10);
    private void OnForwardTen(object sender, RoutedEventArgs e) => AppServices.Mpv?.SeekBy(10);
    private void OnSeekReleased(object sender, PointerRoutedEventArgs e) { AppServices.Mpv?.SeekTo(SeekBar.Value); _dragging = false; }
    private void OnVolume(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e) => AppServices.Mpv?.SetVolume((int)e.NewValue);

    private void OnFullScreen(object sender, RoutedEventArgs e)
    {
        var window = AppServices.MainWindow.AppWindow;
        window.SetPresenter(window.Presenter.Kind == AppWindowPresenterKind.FullScreen ? AppWindowPresenterKind.Default : AppWindowPresenterKind.FullScreen);
        PlaceVideo();
    }

    // ---------- Tools ----------

    private static void AddItem(MenuFlyout flyout, string text, Action action, bool check = false)
    {
        MenuFlyoutItemBase item;
        if (check) { var t = new ToggleMenuFlyoutItem { Text = text, IsChecked = true }; t.Click += (_, _) => action(); item = t; }
        else { var m = new MenuFlyoutItem { Text = text }; m.Click += (_, _) => action(); item = m; }
        flyout.Items.Add(item);
    }

    private void OnAudio(object sender, RoutedEventArgs e)
    {
        var mpv = AppServices.Mpv; if (mpv is null) return;
        var flyout = new MenuFlyout();
        var tracks = mpv.Tracks().Where(t => t.Type == "audio").ToList();
        if (tracks.Count == 0) AddItem(flyout, "No other audio tracks", () => { });
        foreach (var t in tracks) { var id = t.Id; AddItem(flyout, t.Label, () => mpv.SelectAudio(id), t.Selected); }
        flyout.Items.Add(new MenuFlyoutSeparator());
        AddItem(flyout, "Audio 0.5 s earlier", () => mpv.SetAudioDelay(-0.5)); AddItem(flyout, "Audio 0.5 s later", () => mpv.SetAudioDelay(0.5)); AddItem(flyout, "Audio in step", () => mpv.SetAudioDelay(0));
        flyout.ShowAt((FrameworkElement)sender);
    }

    private void OnSubtitles(object sender, RoutedEventArgs e)
    {
        var mpv = AppServices.Mpv; if (mpv is null) return;
        var flyout = new MenuFlyout();
        AddItem(flyout, "Off", () => mpv.SelectSubtitle(null));
        foreach (var t in mpv.Tracks().Where(t => t.Type == "sub")) { var id = t.Id; AddItem(flyout, t.Label, () => mpv.SelectSubtitle(id), t.Selected); }
        flyout.Items.Add(new MenuFlyoutSeparator());
        AddItem(flyout, "Find online…", () => _ = FindSubtitlesAsync(false));
        AddItem(flyout, "From a file…", () => _ = SubtitleFileAsync());
        AddItem(flyout, "Show 0.5 s earlier", () => mpv.SetSubtitleDelay(-0.5)); AddItem(flyout, "Show 0.5 s later", () => mpv.SetSubtitleDelay(0.5)); AddItem(flyout, "In step", () => mpv.SetSubtitleDelay(0));
        AddItem(flyout, "Larger text", () => mpv.SetSubtitleStyle(64, "#FFFFFF", true)); AddItem(flyout, "Smaller text", () => mpv.SetSubtitleStyle(36, "#FFFFFF", true));
        AddItem(flyout, "Yellow text", () => mpv.SetSubtitleStyle(48, "#FFFF00", true)); AddItem(flyout, "White text, no background", () => mpv.SetSubtitleStyle(48, "#FFFFFF", false));
        flyout.ShowAt((FrameworkElement)sender);
    }

    private async Task SubtitleFileAsync()
    {
        var picker = new Windows.Storage.Pickers.FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, AppServices.MainHandle);
        foreach (var ext in new[] { ".srt", ".ass", ".ssa", ".vtt", ".sub" }) picker.FileTypeFilter.Add(ext);
        if (await picker.PickSingleFileAsync() is { } file) AppServices.Mpv?.AddSubtitleFile(file.Path);
    }

    /// <summary>Searches OpenSubtitles with the person's own key. With <paramref name="automatic"/> only a confident match is loaded; otherwise the ranked results are shown with their reasons.</summary>
    private async Task FindSubtitlesAsync(bool automatic)
    {
        if (_request is null) return;
        var key = AppServices.Secrets.Get("opensubtitles:key");
        if (string.IsNullOrEmpty(key)) { if (!automatic) await Dialogs.MessageAsync(XamlRoot, "OpenSubtitles", "Add your free OpenSubtitles key in Settings first."); return; }
        try
        {
            Busy.IsActive = true;
            var language = AppServices.Settings.SubtitleLanguage;
            var found = Subtitles.ParseSearch(await AppServices.Http.FetchTextAsync(Subtitles.SearchUrl(_request.Title, null, language), 4 * 1024 * 1024, headers: Subtitles.Headers(key)));
            var ranked = Subtitles.Rank(found, _request.Title, null, language);
            RankedSubtitle? chosen;
            if (automatic) chosen = Subtitles.Confident(ranked);
            else
            {
                Busy.IsActive = false;
                if (ranked.Count == 0) { await Dialogs.MessageAsync(XamlRoot, "No subtitles found", "Nothing came back for this title in your language."); return; }
                var list = new ListView { SelectionMode = ListViewSelectionMode.Single, MaxHeight = 360, ItemsSource = ranked.Take(15).Select(r => $"{r.Candidate.Release}\n{r.Reason}").ToList(), SelectedIndex = 0 };
                var dialog = new ContentDialog { Title = "Subtitles", Content = list, PrimaryButtonText = "Use this one", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary, XamlRoot = XamlRoot };
                if (VideoWindow.Shown) VideoWindow.Hide(AppServices.VideoHandle);
                if (await dialog.ShowAsync() != ContentDialogResult.Primary || list.SelectedIndex < 0) return;
                chosen = ranked[list.SelectedIndex];
            }
            if (chosen is null) return;
            Busy.IsActive = true;
            var user = AppServices.Settings.OpenSubtitlesUser ?? ""; var pass = AppServices.Secrets.Get("opensubtitles:password") ?? "";
            var token = Subtitles.ParseToken(await AppServices.Http.FetchTextAsync(Subtitles.Host + "/login", 1024 * 1024, headers: Subtitles.Headers(key), method: HttpMethod.Post, body: Subtitles.LoginBody(user, pass)))
                ?? throw new InvalidOperationException("OpenSubtitles did not accept the user name and password in Settings.");
            var link = Subtitles.ParseLink(await AppServices.Http.FetchTextAsync(Subtitles.Host + "/download", 1024 * 1024, headers: Subtitles.Headers(key, token), method: HttpMethod.Post, body: Subtitles.DownloadBody(chosen.Candidate.FileId)))
                ?? throw new InvalidOperationException("OpenSubtitles did not give a download link (the daily limit may be reached).");
            var text = await AppServices.Http.FetchTextAsync(link, 5 * 1024 * 1024);
            var path = Path.Combine(Path.GetTempPath(), "streamsetu-sub-" + Guid.NewGuid().ToString("N") + ".srt");
            await File.WriteAllTextAsync(path, text); _tempFiles.Add(path);
            AppServices.Mpv?.AddSubtitleFile(path);
        }
        catch (Exception ex) when (!automatic) { await Dialogs.MessageAsync(XamlRoot, "Subtitles", ex.Message); }
        catch (Exception) { /* automatic: a failure only means no subtitle */ }
        finally { Busy.IsActive = false; }
    }

    private async Task AutoSubtitlesAsync()
    {
        await Task.Delay(1500);                                                   // let mpv pick the file's own subtitles first
        if (AppServices.Mpv?.Tracks().Any(t => t.Type == "sub") == true) return;   // it has some: nothing to fetch
        await FindSubtitlesAsync(true);
    }

    private void OnSpeed(object sender, RoutedEventArgs e)
    {
        var mpv = AppServices.Mpv; if (mpv is null) return;
        var flyout = new MenuFlyout();
        foreach (var s in new[] { 0.5, 0.75, 1.0, 1.25, 1.5, 2.0 }) { var v = s; AddItem(flyout, $"{s:0.##}×", () => mpv.SetSpeed(v)); }
        flyout.ShowAt((FrameworkElement)sender);
    }

    private async void OnPicture(object sender, RoutedEventArgs e)
    {
        var mpv = AppServices.Mpv; if (mpv is null) return;
        var panel = new StackPanel { Spacing = 8, MinWidth = 320 };
        foreach (var name in new[] { "brightness", "contrast", "saturation", "gamma" })
        {
            var n = name; var s = new Slider { Header = char.ToUpper(n[0]) + n[1..], Minimum = -100, Maximum = 100, Value = 0 };
            s.ValueChanged += (_, args) => mpv.SetPicture(n, (int)args.NewValue); panel.Children.Add(s);
        }
        await Dialogs.ShowCustomAsync(XamlRoot, "Picture", panel, "Done");
    }

    private void OnSleep(object sender, RoutedEventArgs e)
    {
        var flyout = new MenuFlyout();
        foreach (var minutes in new[] { 15, 30, 45, 60, 90 }) { var m = minutes; AddItem(flyout, $"{m} minutes", () => AppServices.Sleep.Start(TimeSpan.FromMinutes(m))); }
        AddItem(flyout, "Off", () => AppServices.Sleep.Cancel());
        flyout.ShowAt((FrameworkElement)sender);
    }

    private async void OnGoTo(object sender, RoutedEventArgs e)
    {
        if (_request is null or { Live: true }) return;
        var text = await Dialogs.AskAsync(XamlRoot, "Go to time", "Time (for example 1:23:45 or 83:45)");
        if (text is null) return;
        var parts = text.Trim().Split(':');
        if (parts.Length is < 1 or > 3 || !parts.All(p => int.TryParse(p, out var n) && n >= 0)) { await Dialogs.MessageAsync(XamlRoot, "Go to time", "Enter a time like 1:23:45 or 83:45."); return; }
        var seconds = parts.Select(int.Parse).Aggregate(0, (acc, n) => acc * 60 + n);
        AppServices.Mpv?.SeekTo(seconds);
    }

    private void OnStats(object sender, RoutedEventArgs e) => AppServices.Mpv?.ToggleStats();

    private void OnScreenshot(object sender, RoutedEventArgs e)
    {
        var folder = Environment.GetFolderPath(Environment.SpecialFolder.MyPictures);
        var path = Path.Combine(folder, $"StreamSetu {DateTime.Now:yyyy-MM-dd HH-mm-ss}.png");
        AppServices.Mpv?.Screenshot(path);
        SubText.Text = "Saved a picture to " + path;
    }

    private async void OnNext(object sender, RoutedEventArgs e)
    {
        if (AppServices.Queue.Items.Count == 0) { SubText.Text = "The queue is empty. Right-click a title and choose Add to queue."; return; }
        await FinishedAsync();
    }

    private void OnSkip(object sender, RoutedEventArgs e) { if (_offer is not null) AppServices.Mpv?.SeekTo(_offer.Target); }

    private void OnMini(object sender, RoutedEventArgs e) => SetMini(!_mini);

    /// <summary>The mini player: a small window that stays above other windows, with just the picture and a slim bar. The menu, the header and the full controls are put away and come back on Restore.</summary>
    private void SetMini(bool on)
    {
        if (on == _mini) return;
        _mini = on;
        var window = AppServices.MainWindow.AppWindow;
        HeaderRow.Visibility = ToolsRow.Visibility = ControlsRow.Visibility = on ? Visibility.Collapsed : Visibility.Visible;
        PipBar.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        if (AppServices.MainWindow is MainWindow main) main.SetChromeVisible(!on);
        if (on) { _restoreSize = window.Size; window.SetPresenter(AppWindowPresenterKind.CompactOverlay); window.Resize(new Windows.Graphics.SizeInt32(480, 330)); }
        else { window.SetPresenter(AppWindowPresenterKind.Default); if (_restoreSize.Width > 0) window.Resize(_restoreSize); }
        PlaceVideo();
    }
}
