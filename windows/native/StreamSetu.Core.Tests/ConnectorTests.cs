using StreamSetu.Core;
using Xunit;

namespace StreamSetu.Core.Tests;

public sealed class ConnectorTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "streamsetu-test-" + Guid.NewGuid().ToString("N"));
    public void Dispose() { try { Directory.Delete(_dir, true); } catch (IOException) { } }

    private static Playlist P(PlaylistKind kind, string address, string? user = null) => new("p", "P", kind, address, user, "playlist:p");
    private static MemorySecretStore Secret(string value = "secret") { var s = new MemorySecretStore(); s.Set("playlist:p", value); return s; }
    private static LibraryLoader Loader(Dictionary<string, string> answers, out LibraryLoaderTests.FakeFetcher fetcher, string secret = "secret") { fetcher = new(answers); return new(fetcher, Secret(secret)); }

    [Fact]
    public async Task HDHomeRun_lists_channels_from_the_lineup()
    {
        var loaded = await Loader(new() { ["lineup.json"] = """[{"GuideNumber":"2.1","GuideName":"KABC","URL":"http://192.168.1.50:5004/auto/v2.1"},{"GuideNumber":"3","GuideName":"No address"},{"GuideNumber":"4.1","GuideName":"Odd","URL":"file:///etc/passwd"}]""" }, out _)
            .LoadAsync(P(PlaylistKind.HdHomeRun, "192.168.1.50"));
        var ch = Assert.Single(loaded.Library.Live);
        Assert.Equal("KABC", ch.Title); Assert.Equal("http://192.168.1.50:5004/auto/v2.1", ch.Url);
    }

    [Fact]
    public async Task TVHeadend_is_asked_with_Basic_authentication_and_streams_carry_the_login_for_the_player()
    {
        var m3u = "#EXTM3U\n#EXTINF:-1 group-title=\"TV\",BBC One\nhttp://tvh.local:9981/stream/channelid/1?profile=pass\n#EXTINF:-1,Elsewhere\nhttp://other.example/x\n";
        var loader = Loader(new() { ["/playlist/channels.m3u"] = m3u }, out var fetcher);
        var loaded = await loader.LoadAsync(P(PlaylistKind.TvHeadend, "http://tvh.local:9981", "me"));
        Assert.Equal("Basic " + Convert.ToBase64String("me:secret"u8.ToArray()), fetcher.Headers.Last()!["Authorization"]);
        Assert.Equal("http://me:secret@tvh.local:9981/stream/channelid/1?profile=pass", loaded.Library.Live.Single(i => i.Title == "BBC One").Url);
        Assert.Equal("http://other.example/x", loaded.Library.Live.Single(i => i.Title == "Elsewhere").Url);        // another host never gets the login
    }

    [Fact]
    public async Task Enigma2_lists_playable_services_by_bouquet_and_skips_bouquets_and_dividers()
    {
        var xml = """
<e2servicelistrecursive>
 <e2bouquet><e2servicereference>1:7:1:0:0:0:0:0:0:0:</e2servicereference><e2servicename>Favourites</e2servicename>
  <e2servicelist>
   <e2service><e2servicereference>1:0:19:283D:3FB:1:C00000:0:0:0:</e2servicereference><e2servicename>Das Erste HD</e2servicename></e2service>
   <e2service><e2servicereference>1:64:1:0:0:0:0:0:0:0:</e2servicereference><e2servicename>-----</e2servicename></e2service>
   <e2service><e2servicereference>1:7:1:0:0:0:0:0:0:0:</e2servicereference><e2servicename>Sub bouquet</e2servicename></e2service>
  </e2servicelist></e2bouquet>
</e2servicelistrecursive>
""";
        var loaded = await Loader(new() { ["/web/getallservices"] = xml }, out _).LoadAsync(P(PlaylistKind.Enigma2, "http://box.local"));
        var ch = Assert.Single(loaded.Library.Live);
        Assert.Equal("Favourites", ch.Group); Assert.Equal("http://box.local:8001/1:0:19:283D:3FB:1:C00000:0:0:0:", ch.Url);
    }

    [Fact]
    public async Task XML_answers_that_try_to_load_files_are_refused()
    {
        var evil = "<?xml version=\"1.0\"?><!DOCTYPE x [<!ENTITY e SYSTEM \"file:///etc/passwd\">]><e2servicelistrecursive>&e;</e2servicelistrecursive>";
        await Assert.ThrowsAsync<InvalidOperationException>(() => Loader(new() { ["/web/getallservices"] = evil }, out _).LoadAsync(P(PlaylistKind.Enigma2, "http://box.local")));
    }

    private const string JellyUsers = """[{"Id":"u1","Name":"someone"},{"Id":"u2","Name":"Me"}]""";

    [Fact]
    public async Task Jellyfin_lists_movies_and_series_for_the_named_user_with_the_key_in_the_stream_address()
    {
        var answers = new Dictionary<string, string>
        {
            ["/Users?api_key="] = JellyUsers,
            ["IncludeItemTypes=Movie"] = """{"Items":[{"Id":"m1","Name":"Heat","ProductionYear":1995,"CommunityRating":8.4,"Genres":["Crime","Drama"],"DateCreated":"2026-10-01T10:00:00.0000000Z"},{"Name":"No id"}]}""",
            ["IncludeItemTypes=Series"] = """{"Items":[{"Id":"s1","Name":"The Show","Genres":[]}]}""",
            ["/Shows/s1/Episodes"] = """{"Items":[{"Id":"e2","Name":"Two","ParentIndexNumber":1,"IndexNumber":2},{"Id":"e1","Name":"One","ParentIndexNumber":1,"IndexNumber":1}]}""",
        };
        var loader = Loader(answers, out var fetcher, "KEY");
        var p = P(PlaylistKind.Jellyfin, "http://jf.local:8096", "me");
        var loaded = await loader.LoadAsync(p);
        Assert.Contains(fetcher.Asked, u => u.Contains("/Users/u2/Items?"));                             // "Me" matched case-insensitively, not the first user
        var movie = Assert.Single(loaded.Library.Movies);
        Assert.Equal("Crime", movie.Group); Assert.Equal(1995, movie.Year); Assert.Equal(4.2, movie.Rating); Assert.Equal("http://jf.local:8096/Videos/m1/stream?static=true&api_key=KEY", movie.Url);
        Assert.Equal("Series", Assert.Single(loaded.Library.Series).Group);
        var eps = await loader.EpisodesAsync(p, loaded, loaded.Library.Series[0]);
        Assert.Equal(new[] { 1, 2 }, eps.Select(e => e.Number).ToArray());
    }

    [Fact]
    public async Task A_media_server_with_no_users_says_so()
    {
        var e = await Assert.ThrowsAsync<InvalidOperationException>(() => Loader(new() { ["/Users?api_key="] = "[]" }, out _).LoadAsync(P(PlaylistKind.Emby, "http://emby.local:8096")));
        Assert.Contains("no users", e.Message);
    }

    [Fact]
    public async Task Plex_lists_movie_and_show_sections_and_asks_for_JSON_with_the_token()
    {
        var answers = new Dictionary<string, string>
        {
            ["/library/sections?"] = """{"MediaContainer":{"Directory":[{"key":"1","type":"movie","title":"Films"},{"key":"2","type":"show","title":"Shows"},{"key":"3","type":"artist","title":"Music"}]}}""",
            ["/library/sections/1/all"] = """{"MediaContainer":{"Metadata":[{"ratingKey":"10","title":"Heat","year":1995,"rating":8.2,"addedAt":1793000000,"Media":[{"Part":[{"key":"/library/parts/55/1/file.mkv"}]}]},{"ratingKey":"11","title":"No file"}]}}""",
            ["/library/sections/2/all"] = """{"MediaContainer":{"Metadata":[{"ratingKey":"20","title":"The Show"}]}}""",
            ["/library/metadata/20/allLeaves"] = """{"MediaContainer":{"Metadata":[{"ratingKey":"21","title":"Pilot","parentIndex":1,"index":1,"Media":[{"Part":[{"key":"/library/parts/70/1/e.mkv"}]}]}]}}""",
        };
        var loader = Loader(answers, out var fetcher, "TOKEN");
        var p = P(PlaylistKind.Plex, "http://plex.local:32400");
        var loaded = await loader.LoadAsync(p);
        Assert.All(fetcher.Headers, h => Assert.Equal("application/json", h!["Accept"]));
        var movies = loaded.Library.Movies;
        Assert.Equal("http://plex.local:32400/library/parts/55/1/file.mkv?X-Plex-Token=TOKEN", movies.Single(m => m.Title == "Heat").Url); Assert.Equal(4.1, movies.Single(m => m.Title == "Heat").Rating);
        Assert.Null(movies.Single(m => m.Title == "No file").Url);
        Assert.Equal("Shows", Assert.Single(loaded.Library.Series).Group);
        var ep = Assert.Single(await loader.EpisodesAsync(p, loaded, loaded.Library.Series[0]));
        Assert.EndsWith("/library/parts/70/1/e.mkv?X-Plex-Token=TOKEN", ep.Url);
    }

    [Fact]
    public async Task WebDAV_walks_folders_lists_video_files_and_ignores_other_servers_and_other_files()
    {
        string Prop(params (string Href, bool Dir)[] e) => "<multistatus xmlns=\"DAV:\">" + string.Concat(e.Select(x => $"<response><href>{x.Href}</href><propstat><prop><resourcetype>{(x.Dir ? "<collection/>" : "")}</resourcetype></prop></propstat></response>")) + "</multistatus>";
        var answers = new Dictionary<string, string>
        {
            ["http://nas.local:5005/videos/Shows/"] = Prop(("/videos/Shows/", true), ("/videos/Shows/The.Show.S01E02.mkv", false), ("/videos/Shows/The.Show.S01E01.mkv", false)),
            ["http://nas.local:5005/videos/"] = Prop(("/videos/", true), ("/videos/Heat.1995.mp4", false), ("/videos/notes.txt", false), ("/videos/Shows/", true), ("http://evil.example/steal.mp4", false)),
        };
        var loader = Loader(answers, out _);
        var loaded = await loader.LoadAsync(P(PlaylistKind.WebDav, "http://nas.local:5005/videos", "me"));
        Assert.Equal("Heat 1995", Assert.Single(loaded.Library.Movies).Title);
        Assert.Equal("http://me:secret@nas.local:5005/videos/Heat.1995.mp4", loaded.Library.Movies[0].Url);
        var show = Assert.Single(loaded.Library.Series);
        Assert.Equal("The Show", show.Title);
        Assert.Equal(new[] { 1, 2 }, (await loader.EpisodesAsync(P(PlaylistKind.WebDav, "x"), loaded, show)).Select(e => e.Number).ToArray());
    }

    [Fact]
    public async Task A_local_folder_lists_video_files_sorted_into_movies_and_shows_without_following_links()
    {
        Directory.CreateDirectory(Path.Combine(_dir, "Films")); Directory.CreateDirectory(Path.Combine(_dir, "Shows", "The Show"));
        File.WriteAllText(Path.Combine(_dir, "Films", "Heat.1995.mkv"), ""); File.WriteAllText(Path.Combine(_dir, "Films", "readme.txt"), "");
        File.WriteAllText(Path.Combine(_dir, "Shows", "The Show", "The.Show.S02E01.mp4"), ""); File.WriteAllText(Path.Combine(_dir, "Shows", "The Show", "The.Show.S01E05.mp4"), "");
        try { Directory.CreateSymbolicLink(Path.Combine(_dir, "Loop"), _dir); } catch (Exception) { /* links need rights on some systems; the scan must work either way */ }
        var loaded = await Loader(new(), out _).LoadAsync(P(PlaylistKind.LocalFolder, _dir));
        Assert.Equal("Heat 1995", Assert.Single(loaded.Library.Movies).Title);
        var eps = loaded.Library.Episodes["the show"];
        Assert.Equal(new[] { (1, 5), (2, 1) }, eps.Select(e => (e.Season!.Value, e.Episode!.Value)).ToArray());
        Assert.Throws<InvalidOperationException>(() => LocalFiles.Scan(Path.Combine(_dir, "missing")));
    }

    [Fact]
    public async Task Testing_a_connection_that_is_not_saved_uses_the_password_given_not_the_store()
    {
        var loader = Loader(new() { ["/Users?api_key=GIVEN"] = "[]" }, out _, secret: "OLD");
        var e = await Assert.ThrowsAsync<InvalidOperationException>(() => loader.LoadAsync(P(PlaylistKind.Jellyfin, "http://jf.local"), default, "GIVEN"));
        Assert.Contains("no users", e.Message);          // it asked with GIVEN (the fake only answers that); with OLD it would have been a 404
    }
}
