using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using StreamSetu.Core;

namespace StreamSetu.App;

/// <summary>What is on now and next, a programme list per channel with catch-up for past programmes, Tonight (favorite channels) and Alerts (words the person asked to be told about).</summary>
public sealed partial class GuidePage : Page
{
    private Playlist? _playlist;
    private LoadedLibrary? _loaded;
    private Guide? _guide;
    private int _loadId;
    private bool _quiet;

    public GuidePage() { InitializeComponent(); }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        var playlists = AppServices.Playlists().ToList();
        if (playlists.Count == 0) { Say("Add a connection first.", InfoBarSeverity.Informational); return; }
        PlaylistBox.ItemsSource = playlists;
        PlaylistBox.Visibility = playlists.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        PlaylistBox.SelectedIndex = 0;
    }

    private void Say(string text, InfoBarSeverity s) { Message.Message = text; Message.Severity = s; Message.IsOpen = true; }

    private async void OnChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_quiet || PlaylistBox.SelectedItem is not Playlist p) return;
        if (_playlist?.Id != p.Id || _guide is null) await LoadAsync(p); else Show();
    }

    private async Task LoadAsync(Playlist p)
    {
        var mine = ++_loadId; _playlist = p; _guide = null; Message.IsOpen = false; Busy.IsActive = true; List.ItemsSource = null;
        try
        {
            var loaded = await AppServices.LoadAsync(p);
            var guide = await AppServices.GuideAsync(p);
            if (mine != _loadId) return;
            if (guide is null) { Say(p.Kind == PlaylistKind.Xtream ? "This connection has no guide." : "This connection has no guide address. Add one under Settings, TV guide.", InfoBarSeverity.Informational); return; }
            _loaded = loaded; _guide = guide; Show();
        }
        catch (Exception ex) { if (mine == _loadId) Say(ex.Message, InfoBarSeverity.Error); }
        finally { if (mine == _loadId) Busy.IsActive = false; }
    }

    private void OnSearch(object sender, TextChangedEventArgs e) { if (_guide is not null) Show(); }

    private static string Time(DateTimeOffset t) => t.ToLocalTime().ToString("HH:mm");

    private void Show()
    {
        if (_guide is null || _loaded is null || _playlist is null) return;
        var now = DateTimeOffset.UtcNow;
        var rows = new List<Row>();
        if (ViewBox.SelectedIndex == 2)
        {
            var words = AppServices.Settings.AlertWords;
            if (words.Count == 0) { Say("Add words (a team, a show) under Settings, TV guide, and programmes with them show here.", InfoBarSeverity.Informational); List.ItemsSource = rows; return; }
            Message.IsOpen = false;
            var byEpg = _loaded.Library.Live.Where(c => c.EpgId is not null).GroupBy(c => c.EpgId!, StringComparer.OrdinalIgnoreCase).ToDictionary(g => g.Key, g => g.First(), StringComparer.OrdinalIgnoreCase);
            foreach (var p in _guide.Alerts(words, now, now.AddDays(3)).Take(300))
                rows.Add(new Row(byEpg.GetValueOrDefault(p.ChannelId) ?? new Item { Id = "x", Kind = Kind.Live, Title = p.ChannelId, Group = "" }, p.Title,
                    $"{p.Start.ToLocalTime():ddd d MMM HH:mm}  ·  {byEpg.GetValueOrDefault(p.ChannelId)?.Title ?? p.ChannelId}", ""));
            if (rows.Count == 0) Say("Nothing with your words is coming up in the next three days.", InfoBarSeverity.Informational);
        }
        else
        {
            Message.IsOpen = false;
            IEnumerable<Item> channels = _loaded.Library.Live;
            if (ViewBox.SelectedIndex == 0)
            {
                var favs = AppServices.User.Favorites().ToHashSet();
                channels = channels.Where(c => favs.Contains(AppServices.KeyOf(_playlist, c)));
                if (!channels.Any()) Say("Right-click channels under Live TV and choose Add to favorites; they show here with what is on.", InfoBarSeverity.Informational);
            }
            channels = LibraryLoader.Search(channels, SearchBox.Text ?? "").Where(c => ViewBox.SelectedIndex == 0 || _guide.Now(c.EpgId, now) is not null || _guide.Next(c.EpgId, now) is not null);
            foreach (var c in channels.Take(2000))
            {
                var on = _guide.Now(c.EpgId, now); var next = _guide.Next(c.EpgId, now);
                rows.Add(new Row(c, c.Title, (on is null ? "Nothing listed now" : $"Now: {on.Title} ({Time(on.Start)}–{Time(on.Stop)})") + (next is null ? "" : $"   Next: {next.Title} ({Time(next.Start)})"), "", c.Logo));
            }
        }
        List.ItemsSource = rows;
    }

    /// <summary>The address to record a channel from. A recording copies the stream's bytes, so it needs a direct stream (.ts); an HLS playlist (.m3u8) is only a list of pieces. Xtream channels are asked for as .ts.</summary>
    private string? RecordingUrl(Item channel)
    {
        if (_playlist is null || channel.Url is null) return null;
        if (_playlist.Kind == PlaylistKind.Xtream && AppServices.Secrets.Get(_playlist.SecretRef ?? LibraryLoader.SecretKey(_playlist.Id)) is { } password)
            return Xtream.StreamUrl(_playlist.Address, _playlist.Username ?? "", password, Kind.Live, channel.Id[(channel.Id.IndexOf(':') + 1)..], "ts");
        var path = channel.Url.Split('?')[0];
        return path.EndsWith(".m3u8", StringComparison.OrdinalIgnoreCase) ? null : channel.Url;
    }

    private async void OnClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not Row { Item: var channel } || _guide is null || _playlist is null) return;
        var now = DateTimeOffset.UtcNow;
        // Coming up first, then what has finished and is still in the provider's archive (catch-up).
        var upcoming = _guide.Between(channel.EpgId, now, now.AddHours(24)).Where(p => p.Stop > now).ToList();
        var past = _guide.Past(channel.EpgId, now, 3).Take(40).ToList();
        var canCatchUp = _playlist.Kind == PlaylistKind.Xtream;
        var labels = upcoming.Select(p => $"{p.Start.ToLocalTime():ddd HH:mm}  {p.Title}").Concat(past.Select(p => $"{p.Start.ToLocalTime():ddd HH:mm}  {p.Title}" + (canCatchUp ? "   ▶ catch-up" : ""))).ToList();
        if (labels.Count == 0) { Say("Nothing is listed for this channel.", InfoBarSeverity.Informational); return; }

        var list = new ListView { SelectionMode = ListViewSelectionMode.Single, MaxHeight = 380, ItemsSource = labels, SelectedIndex = 0 };
        var remind = new Button { Content = "Remind me" }; var record = new Button { Content = "Record" };
        string action = "";
        var panel = new StackPanel { Spacing = 10 };
        panel.Children.Add(list);
        panel.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { remind, record } });
        var dialog = new ContentDialog { Title = channel.Title, Content = panel, PrimaryButtonText = "Watch", CloseButtonText = "Close", DefaultButton = ContentDialogButton.Primary, XamlRoot = XamlRoot };
        remind.Click += (_, _) => { action = "remind"; dialog.Hide(); };
        record.Click += (_, _) => { action = "record"; dialog.Hide(); };
        var result = await dialog.ShowAsync();
        if (list.SelectedIndex < 0) return;
        var index = list.SelectedIndex;

        try
        {
            if (action is "remind" or "record")
            {
                if (index >= upcoming.Count) { Say("Choose a programme that has not ended.", InfoBarSeverity.Warning); return; }
                var p = upcoming[index];
                if (action == "remind")
                {
                    var added = AppServices.Reminders.Add(channel.Title, p.Title, p.Start, 5, now);
                    Say(added ? $"You will be told 5 minutes before “{p.Title}” on {channel.Title} ({p.Start.ToLocalTime():ddd HH:mm})." : "There is already a reminder for that, or it has started.", added ? InfoBarSeverity.Success : InfoBarSeverity.Informational);
                }
                else
                {
                    var url = RecordingUrl(channel);
                    if (url is null) { Say("This channel is an HLS playlist, which cannot be recorded here. Recording works with direct streams (.ts).", InfoBarSeverity.Warning); return; }
                    var (rec, warning) = AppServices.Recordings.Add($"{channel.Title} {p.Title}", url, p.Start, p.Stop, now);
                    Say($"Scheduled “{p.Title}” ({rec.Start.ToLocalTime():ddd HH:mm}–{rec.Stop.ToLocalTime():HH:mm}). StreamSetu must be open at that time." + (warning is null ? "" : " " + warning), warning is null ? InfoBarSeverity.Success : InfoBarSeverity.Warning);
                }
                return;
            }
            if (result != ContentDialogResult.Primary) return;

            var key = AppServices.KeyOf(_playlist, channel);
            if (index < upcoming.Count)
            {
                // A programme still to come (or on now): watch the channel live.
                if (channel.Url is not null) Frame.Navigate(typeof(PlayerPage), new PlayRequest(_playlist, key, channel.Title, await AppServices.PlayUrlAsync(_playlist, channel.Url), true, 0, channel));
                return;
            }
            if (!canCatchUp) { Say("Catch-up is available for Xtream connections.", InfoBarSeverity.Informational); return; }
            var programme = past[index - upcoming.Count];
            var password = AppServices.Secrets.Get(_playlist.SecretRef ?? LibraryLoader.SecretKey(_playlist.Id));
            if (password is null) { Say("The saved password could not be found.", InfoBarSeverity.Error); return; }
            var streamId = channel.Id[(channel.Id.IndexOf(':') + 1)..];
            var minutes = (int)Math.Ceiling((programme.Stop - programme.Start).TotalMinutes);
            var catchUp = Xtream.CatchupUrl(_playlist.Address, _playlist.Username ?? "", password, streamId, programme.Start, minutes);
            Frame.Navigate(typeof(PlayerPage), new PlayRequest(_playlist, key + "|" + programme.Start.ToUnixTimeSeconds(), $"{channel.Title}: {programme.Title}", catchUp, false, 0));
        }
        catch (Exception ex) when (ex is ArgumentException or InvalidOperationException) { Say(ex.Message, InfoBarSeverity.Error); }
    }
}
