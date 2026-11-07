using StreamSetu.Core;
using Xunit;

namespace StreamSetu.Core.Tests;

public sealed class LocalStoreTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "streamsetu-test-" + Guid.NewGuid().ToString("N"));
    private long _clock = 1_000;
    private LocalStore Store() => new(_dir, () => _clock++);
    public void Dispose() { try { Directory.Delete(_dir, true); } catch (IOException) { } }

    [Fact]
    public void Keeps_playlists_without_a_password_and_removes_them()
    {
        var s = Store();
        s.AddPlaylist(new Playlist("a", "A", PlaylistKind.Xtream, "http://h", "u", "playlist:a"));
        Assert.Single(s.Playlists());
        Assert.DoesNotContain("password", File.ReadAllText(Path.Combine(_dir, "Playlists.json")), StringComparison.OrdinalIgnoreCase);
        s.RemovePlaylist("a"); Assert.Empty(s.Playlists());
    }

    [Fact]
    public void Adding_a_playlist_again_replaces_it_and_survives_a_restart()
    {
        Store().AddPlaylist(new Playlist("a", "Old", PlaylistKind.M3u, "http://h/a.m3u"));
        Store().AddPlaylist(new Playlist("a", "New", PlaylistKind.M3u, "http://h/a.m3u"));
        var back = Store().Playlists();
        Assert.Equal("New", Assert.Single(back).Name); Assert.Equal(PlaylistKind.M3u, back[0].Kind);
    }

    [Fact]
    public void Toggles_favourites_newest_first()
    {
        var s = Store();
        Assert.True(s.ToggleFavorite("x")); Assert.True(s.ToggleFavorite("y"));
        Assert.Equal(new[] { "y", "x" }, s.Favorites());
        Assert.False(s.ToggleFavorite("x")); Assert.False(s.IsFavorite("x"));
    }

    [Fact]
    public void Remembers_a_place_and_forgets_a_finished_title()
    {
        var s = Store();
        s.SaveProgress("m", 600, 7200); Assert.Equal(600, s.ProgressOf("m")?.Position);
        s.SaveProgress("m", 7190, 7200); Assert.Null(s.ProgressOf("m"));
        s.SaveProgress("n", 5, 7200); Assert.Null(s.ProgressOf("n"));            // the first seconds are not worth remembering
        s.SaveProgress("o", 7000, 7200); Assert.Null(s.ProgressOf("o"));         // past 95%
    }

    [Fact]
    public void Lists_part_watched_titles_most_recent_first_and_keeps_300()
    {
        var s = Store();
        s.SaveProgress("first", 100, 5000); s.SaveProgress("second", 100, 5000);
        Assert.Equal(new[] { "second", "first" }, s.RecentProgress().Select(p => p.Key).ToArray());
        for (int i = 0; i < 310; i++) s.SaveProgress("t" + i, 100, 5000);
        Assert.Equal(300, s.RecentProgress().Count);
    }

    [Fact]
    public void An_unreadable_file_is_set_aside_never_overwritten()
    {
        Directory.CreateDirectory(_dir);
        var path = Path.Combine(_dir, "Playlists.json");
        File.WriteAllText(path, "{ this is not json");
        var s = Store();
        Assert.Empty(s.Playlists());
        s.AddPlaylist(new Playlist("a", "A", PlaylistKind.M3u, "http://h"));
        var kept = Directory.GetFiles(_dir, "Playlists.json.unreadable-*");
        Assert.Equal("{ this is not json", File.ReadAllText(Assert.Single(kept)));
        Assert.Single(s.Playlists());
    }

    [Fact]
    public void A_save_leaves_no_temporary_file_behind()
    {
        var s = Store(); s.ToggleFavorite("x");
        Assert.Empty(Directory.GetFiles(_dir, "*.tmp"));
    }
}
