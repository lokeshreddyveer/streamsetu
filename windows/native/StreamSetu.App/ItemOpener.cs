using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using StreamSetu.Core;

namespace StreamSetu.App;

/// <summary>Opens a title from any screen: a series asks which episode, a movie or channel plays (from where it was left, for a movie).</summary>
internal static class ItemOpener
{
    public static async Task OpenAsync(Frame frame, XamlRoot root, Playlist playlist, LoadedLibrary loaded, Item item, Action<bool> busy, Action<string, InfoBarSeverity> say)
    {
        try
        {
            if (item.Kind == Kind.Series) { await ChooseEpisodeAsync(frame, root, playlist, loaded, item, busy, say); return; }
            if (item.Url is null) return;
            var key = AppServices.KeyOf(playlist, item);
            var start = item.Kind == Kind.Movie ? AppServices.User.ProgressOf(key)?.Position ?? 0 : 0;
            busy(true);
            string url;
            try { url = await AppServices.PlayUrlAsync(playlist, item.Url); }           // a Stalker portal gives a fresh link each time; every other kind returns the address as it is
            finally { busy(false); }
            frame.Navigate(typeof(PlayerPage), new PlayRequest(playlist, key, item.Title, url, item.Kind == Kind.Live, start, item.Kind == Kind.Live ? item : null));
        }
        catch (Exception ex) { say(ex.Message, InfoBarSeverity.Error); }
    }

    private static async Task ChooseEpisodeAsync(Frame frame, XamlRoot root, Playlist playlist, LoadedLibrary loaded, Item series, Action<bool> busy, Action<string, InfoBarSeverity> say)
    {
        busy(true);
        List<Episode> episodes;
        try { episodes = await AppServices.Loader.EpisodesAsync(playlist, loaded, series); }
        finally { busy(false); }
        if (episodes.Count == 0) { say("No episodes were listed for this series.", InfoBarSeverity.Informational); return; }

        var watched = AppServices.User.Watched();
        var labels = episodes.Select(ep => $"{(watched.Contains(playlist.Id + "|" + ep.Id) ? "✓ " : "")}Season {ep.Season}, episode {ep.Number}: {ep.Title}").ToList();
        // Up Next: the first episode not yet watched is chosen to begin with.
        var list = new ListView { SelectionMode = ListViewSelectionMode.Single, MaxHeight = 420, ItemsSource = labels };
        var firstNew = episodes.FindIndex(ep => !watched.Contains(playlist.Id + "|" + ep.Id));
        list.SelectedIndex = firstNew >= 0 ? firstNew : 0;
        var dialog = new ContentDialog { Title = series.Title, Content = list, PrimaryButtonText = "Play", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary, XamlRoot = root };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || list.SelectedIndex < 0) return;
        var chosen = episodes[list.SelectedIndex];
        var key = playlist.Id + "|" + chosen.Id;
        frame.Navigate(typeof(PlayerPage), new PlayRequest(playlist, key, $"{series.Title}: {chosen.Title}", await AppServices.PlayUrlAsync(playlist, chosen.Url), false, AppServices.User.ProgressOf(key)?.Position ?? 0));
    }
}
