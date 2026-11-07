using StreamSetu.Core;
using Xunit;

namespace StreamSetu.Core.Tests;

public class LibraryLoaderTests
{
    internal sealed class FakeFetcher(Dictionary<string, string> answers) : ITextFetcher
    {
        public List<string> Asked { get; } = new();
        public List<IReadOnlyDictionary<string, string>?> Headers { get; } = new();
        public Task<string> FetchAsync(string url, CancellationToken ct = default) => FetchAsync(url, null, ct);
        public Task<string> FetchAsync(string url, IReadOnlyDictionary<string, string>? headers, CancellationToken ct = default, string method = "GET", string? body = null)
        {
            Asked.Add(url); Headers.Add(headers);
            foreach (var (needle, answer) in answers) if (url.Contains(needle)) return Task.FromResult(answer);
            throw new InvalidOperationException("The server answered 404.");
        }
    }

    private static readonly Playlist Panel = new("p1", "Panel", PlaylistKind.Xtream, "http://panel.example:8080", "u", "playlist:p1");
    private static MemorySecretStore Secrets() { var s = new MemorySecretStore(); s.Set("playlist:p1", "pw"); return s; }

    private static Dictionary<string, string> Answers(string account = """{"user_info":{"auth":1,"status":"Active","exp_date":"1893456000","max_connections":"1"}}""") => new()
    {
        ["action=get_live_categories"] = """[{"category_id":"1","category_name":"UK"}]""",
        ["action=get_live_streams"] = """[{"stream_id":1,"name":"BBC One","category_id":"1"}]""",
        ["action=get_vod_categories"] = "[]",
        ["action=get_vod_streams"] = """[{"stream_id":9,"name":"Heat","container_extension":"mkv"}]""",
        ["action=get_series_categories"] = "[]",
        ["action=get_series_info"] = """{"episodes":{"1":[{"id":"20","episode_num":1,"title":"One"}]}}""",
        ["action=get_series"] = """[{"series_id":5,"name":"The Show"}]""",
        ["player_api.php?username"] = account,
    };

    [Fact]
    public async Task Loads_an_Xtream_panel_into_live_movies_and_series()
    {
        var loaded = await new LibraryLoader(new FakeFetcher(Answers()), Secrets()).LoadAsync(Panel);
        Assert.Equal("BBC One", Assert.Single(loaded.Library.Live).Title); Assert.Single(loaded.Library.Movies); Assert.Single(loaded.Library.Series);
        Assert.True(loaded.Account!.Active);
    }

    [Fact]
    public async Task The_password_comes_from_the_secret_store_and_is_not_in_the_saved_playlist()
    {
        var fetcher = new FakeFetcher(Answers());
        await new LibraryLoader(fetcher, Secrets()).LoadAsync(Panel);
        Assert.All(fetcher.Asked, u => Assert.Contains("password=pw", u));
        Assert.DoesNotContain("pw", System.Text.Json.JsonSerializer.Serialize(Panel));
    }

    [Fact]
    public async Task A_missing_saved_password_says_so()
    {
        var e = await Assert.ThrowsAsync<InvalidOperationException>(() => new LibraryLoader(new FakeFetcher(Answers()), new MemorySecretStore()).LoadAsync(Panel));
        Assert.Contains("password", e.Message);
    }

    [Fact]
    public async Task A_refused_login_and_an_expired_subscription_stop_the_load_with_a_clear_message()
    {
        var refused = await Assert.ThrowsAsync<InvalidOperationException>(() => new LibraryLoader(new FakeFetcher(Answers("""{"user_info":{"auth":0}}""")), Secrets()).LoadAsync(Panel));
        Assert.Contains("refused", refused.Message);
        var expired = await Assert.ThrowsAsync<InvalidOperationException>(() => new LibraryLoader(new FakeFetcher(Answers("""{"user_info":{"auth":1,"status":"Expired"}}""")), Secrets()).LoadAsync(Panel));
        Assert.Contains("expired", expired.Message);
    }

    [Fact]
    public async Task A_panel_without_series_still_shows_its_channels()
    {
        var answers = Answers(); answers.Remove("action=get_series_categories"); answers.Remove("action=get_series");
        var loaded = await new LibraryLoader(new FakeFetcher(answers), Secrets()).LoadAsync(Panel);
        Assert.Single(loaded.Library.Live); Assert.Empty(loaded.Library.Series);
    }

    [Fact]
    public async Task Something_that_is_not_JSON_is_reported_as_a_wrong_address()
    {
        var answers = Answers("<html>Not a panel</html>");
        var e = await Assert.ThrowsAsync<InvalidOperationException>(() => new LibraryLoader(new FakeFetcher(answers), Secrets()).LoadAsync(Panel));
        Assert.Contains("address", e.Message);
    }

    [Fact]
    public async Task Loads_an_M3U_link_and_lists_a_show_s_episodes()
    {
        var m3u = new Playlist("m", "List", PlaylistKind.M3u, "http://h/list.m3u");
        var text = "#EXTM3U\n#EXTINF:-1 group-title=\"Series\",Show S01E02\nhttp://h/series/a/b/2.mp4\n#EXTINF:-1 group-title=\"Series\",Show S01E01\nhttp://h/series/a/b/1.mp4\n";
        var loader = new LibraryLoader(new FakeFetcher(new() { ["list.m3u"] = text }), new MemorySecretStore());
        var loaded = await loader.LoadAsync(m3u);
        var eps = await loader.EpisodesAsync(m3u, loaded, loaded.Library.Series[0]);
        Assert.Equal(new[] { 1, 2 }, eps.Select(e => e.Number).ToArray());
    }

    [Fact]
    public async Task Loads_the_episodes_of_an_Xtream_series()
    {
        var loader = new LibraryLoader(new FakeFetcher(Answers()), Secrets());
        var loaded = await loader.LoadAsync(Panel);
        var eps = await loader.EpisodesAsync(Panel, loaded, loaded.Library.Series[0]);
        Assert.Equal("http://panel.example:8080/series/u/pw/20.mp4", Assert.Single(eps).Url);
    }

    [Fact]
    public void Search_matches_every_word_in_the_title_or_folder()
    {
        var items = new[] { new Item { Id = "1", Kind = Kind.Live, Title = "BBC One HD", Group = "UK" }, new Item { Id = "2", Kind = Kind.Live, Title = "Sky News", Group = "UK" }, new Item { Id = "3", Kind = Kind.Live, Title = "CNN", Group = "US" } };
        Assert.Equal(2, LibraryLoader.Search(items, "uk").Count);
        Assert.Equal("Sky News", Assert.Single(LibraryLoader.Search(items, "sky uk")).Title);
        Assert.Equal(3, LibraryLoader.Search(items, "  ").Count);
        Assert.Empty(LibraryLoader.Search(items, "nothing"));
    }
}
