using StreamSetu.Core;
using Xunit;

namespace StreamSetu.Core.Tests;

public class StalkerTests
{
    private const string Mac = "00:1A:79:12:34:56";
    private static readonly Playlist Portal = new("s", "Portal", PlaylistKind.Stalker, "http://portal.example:8080/c/", null, "playlist:s");

    private static Dictionary<string, string> Answers() => new()
    {
        ["action=handshake"] = """{"js":{"token":"TOK123"}}""",
        ["action=get_profile"] = """{"js":{"id":"1"}}""",
        ["action=get_genres"] = """{"js":[{"id":"1","title":"News"},{"id":"2","title":"Sport"}]}""",
        ["action=get_all_channels"] = """{"js":{"data":[{"id":"10","name":"BBC News","cmd":"ffmpeg http://localhost/ch/10","tv_genre_id":"1","logo":"http://logos/bbc.png"},{"id":"11","name":"No command"},{"id":"12","name":"Sky Sports","cmd":"ffrt http://localhost/ch/12","tv_genre_id":"2"}]}}""",
        ["action=get_ordered_list&p=1"] = """{"js":{"data":[{"id":"100","name":"Heat","cmd":"/media/file_100.mpg","year":"1995"}]}}""",
        ["action=get_ordered_list&p=2"] = """{"js":{"data":[]}}""",
        ["action=create_link"] = """{"js":{"cmd":"ffmpeg http://stream.example/live/abc?token=zzz"}}""",
    };

    private static LibraryLoader Loader(Dictionary<string, string> a, out LibraryLoaderTests.FakeFetcher f) { f = new(a); var s = new MemorySecretStore(); s.Set("playlist:s", Mac); return new(f, s); }

    [Fact]
    public void The_server_script_is_found_from_what_people_paste()
    {
        Assert.Equal("http://portal.example:8080/server/load.php", StalkerClient.LoadUrl("http://portal.example:8080/c/"));
        Assert.Equal("http://portal.example/stalker_portal/server/load.php", StalkerClient.LoadUrl("http://portal.example/stalker_portal/c/"));
        Assert.Equal("http://portal.example/server/load.php", StalkerClient.LoadUrl("http://portal.example/portal.php?x=1"));          // any other path: the usual place under the host
        Assert.Equal("http://portal.example/custom/load.php", StalkerClient.LoadUrl("http://portal.example/custom/load.php?type=stb"));
    }

    [Theory]
    [InlineData("00:1A:79:12:34:56", true)] [InlineData("00:1a:79:12:34:56", true)] [InlineData("00-1A-79-12-34-56", false)] [InlineData("00:1A:79:12:34", false)] [InlineData("", false)] [InlineData("ZZ:1A:79:12:34:56", false)]
    public void A_MAC_address_looks_like_six_pairs(string mac, bool ok) => Assert.Equal(ok, StalkerClient.IsMac(mac));

    [Fact]
    public async Task Loads_channels_with_their_genre_and_logo_and_films_a_page_at_a_time()
    {
        var loaded = await Loader(Answers(), out var f).LoadAsync(Portal);
        Assert.Equal(new[] { "BBC News", "Sky Sports" }, loaded.Library.Live.Select(c => c.Title).ToArray());
        Assert.Equal("News", loaded.Library.Live[0].Group); Assert.Equal("http://logos/bbc.png", loaded.Library.Live[0].Logo); Assert.Null(loaded.Library.Live[1].Logo);
        Assert.StartsWith("stalker:itv:", loaded.Library.Live[0].Url);
        var film = Assert.Single(loaded.Library.Movies); Assert.Equal(1995, film.Year); Assert.StartsWith("stalker:vod:", film.Url);
        Assert.Contains(f.Headers, h => h is not null && h["Cookie"].StartsWith("mac=00:1A:79:12:34:56"));
        Assert.Contains(f.Headers, h => h is not null && h.ContainsKey("Authorization") && h["Authorization"] == "Bearer TOK123");     // after the handshake, every call carries the token
    }

    [Fact]
    public async Task A_portal_that_does_not_know_the_MAC_or_answers_with_a_web_page_says_so()
    {
        var unknown = Answers(); unknown["action=handshake"] = """{"js":{"token":""}}""";
        Assert.Contains("MAC", (await Assert.ThrowsAsync<InvalidOperationException>(() => Loader(unknown, out _).LoadAsync(Portal))).Message);
        var page = Answers(); page["action=handshake"] = "<html>Login</html>";
        Assert.Contains("address", (await Assert.ThrowsAsync<InvalidOperationException>(() => Loader(page, out _).LoadAsync(Portal))).Message);
        var s = new MemorySecretStore(); s.Set("playlist:s", "not-a-mac");
        await Assert.ThrowsAsync<InvalidOperationException>(() => new LibraryLoader(new LibraryLoaderTests.FakeFetcher(Answers()), s).LoadAsync(Portal));
    }

    [Fact]
    public async Task A_channel_is_played_through_a_fresh_link_asked_for_at_play_time()
    {
        var loader = Loader(Answers(), out var f);
        var loaded = await loader.LoadAsync(Portal);
        var url = await loader.ResolvePlayUrlAsync(Portal, loaded.Library.Live[0].Url!);
        Assert.Equal("http://stream.example/live/abc?token=zzz", url);                                                 // "ffmpeg " removed
        Assert.Contains(f.Asked, a => a.Contains("action=create_link") && a.Contains("cmd=ffmpeg%20http%3A%2F%2Flocalhost%2Fch%2F10"));
        Assert.Equal("http://other.example/a.ts", await loader.ResolvePlayUrlAsync(Portal, "http://other.example/a.ts"));    // anything else is used as it is
    }

    [Fact]
    public async Task A_link_that_is_not_a_web_address_is_refused()
    {
        var a = Answers(); a["action=create_link"] = """{"js":{"cmd":"file:///c:/windows/system32/cmd.exe"}}""";
        var loader = Loader(a, out _);
        var loaded = await loader.LoadAsync(Portal);
        await Assert.ThrowsAsync<InvalidOperationException>(() => loader.ResolvePlayUrlAsync(Portal, loaded.Library.Live[0].Url!));
        var b = Answers(); b["action=create_link"] = """{"js":{"cmd":"rtmp://x/y"}}""";
        await Assert.ThrowsAsync<InvalidOperationException>(() => Loader(b, out _).ResolvePlayUrlAsync(Portal, "stalker:itv:x"));
    }
}
