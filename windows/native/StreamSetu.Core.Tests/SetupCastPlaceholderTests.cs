using StreamSetu.Core;
using Xunit;

namespace StreamSetu.Core.Tests;

public class SetupTests
{
    [Fact]
    public void PasteIsRecognised()
    {
        var x = SetupPaste.Detect("http://panel.example:8080/get.php?username=bob&password=s3cret&type=m3u_plus")!;
        Assert.Equal(PlaylistKind.Xtream, x.Kind); Assert.Equal("http://panel.example:8080", x.Address); Assert.Equal("bob", x.User); Assert.Equal("s3cret", x.Secret);
        Assert.Equal(PlaylistKind.M3u, SetupPaste.Detect(" https://x.example/list.m3u8 ")!.Kind);
        Assert.Equal(PlaylistKind.SingleStream, SetupPaste.Detect("https://x.example/live/ch1.ts")!.Kind);
        Assert.Equal(PlaylistKind.SingleStream, SetupPaste.Detect("rtmp://x.example/live/ch1")!.Kind);
        Assert.Equal(PlaylistKind.Stalker, SetupPaste.Detect("http://portal.example:8080/c/")!.Kind);
        Assert.Equal(PlaylistKind.Plex, SetupPaste.Detect("http://10.0.0.5:32400/?X-Plex-Token=abc")!.Kind);
        Assert.Equal("abc", SetupPaste.Detect("http://10.0.0.5:32400/?X-Plex-Token=abc")!.Secret);
        Assert.Equal(PlaylistKind.Jellyfin, SetupPaste.Detect("http://10.0.0.5:8096")!.Kind);
        Assert.Equal(PlaylistKind.TvHeadend, SetupPaste.Detect("http://10.0.0.6:9981")!.Kind);
        Assert.Equal(PlaylistKind.HdHomeRun, SetupPaste.Detect("http://10.0.0.7/lineup.json")!.Kind);
        Assert.Equal(PlaylistKind.M3u, SetupPaste.Detect(@"C:\Users\me\list.m3u")!.Kind);
        Assert.Null(SetupPaste.Detect("")); Assert.Null(SetupPaste.Detect("hello there")); Assert.Null(SetupPaste.Detect(@"C:\notes.txt"));
    }

    [Fact]
    public void DraftKeepsNoSecretsAndClearsWhenEmpty()
    {
        var dir = Path.Combine(Path.GetTempPath(), "ss-draft-" + Guid.NewGuid().ToString("N"));
        var drafts = new SetupDrafts(new LocalStore(dir));
        Assert.Null(drafts.Load());
        drafts.Save(new SetupDraft(PlaylistKind.Xtream, "Mine", "http://x", "bob"));
        var back = drafts.Load()!; Assert.Equal("Mine", back.Name); Assert.Equal("bob", back.User); Assert.Equal(PlaylistKind.Xtream, back.Kind);
        Assert.DoesNotContain("pass", File.ReadAllText(Path.Combine(dir, "SetupDraft.json")), StringComparison.OrdinalIgnoreCase);
        drafts.Save(new SetupDraft(PlaylistKind.Xtream, "", " ", null)); Assert.Null(drafts.Load());
        drafts.Save(new SetupDraft(PlaylistKind.M3u, "a", "b", null)); drafts.Clear(); Assert.Null(drafts.Load());
        Directory.Delete(dir, true);
    }

    [Fact]
    public async Task ASingleStreamIsOneLiveChannel()
    {
        var loader = new LibraryLoader(new NoFetch(), new NoSecrets());
        var lib = (await loader.LoadAsync(new Playlist("p", "News", PlaylistKind.SingleStream, "https://x.example/live/ch1.ts"))).Library;
        var ch = Assert.Single(lib.Live);
        Assert.Equal("News", ch.Title); Assert.Equal("https://x.example/live/ch1.ts", ch.Url); Assert.Empty(lib.Movies);
    }

    private sealed class NoFetch : ITextFetcher
    {
        public Task<string> FetchAsync(string url, CancellationToken ct = default) => throw new InvalidOperationException("no network");
        public Task<string> FetchAsync(string url, IReadOnlyDictionary<string, string>? headers, CancellationToken ct = default, string method = "GET", string? body = null) => throw new InvalidOperationException("no network");
    }

    private sealed class NoSecrets : ISecretStore
    {
        public void Set(string key, string value) { }
        public string? Get(string key) => null;
        public void Delete(string key) { }
    }
}

public class PlaceholderTests
{
    [Fact]
    public void MonogramAndHueAreStable()
    {
        Assert.Equal("TM", Placeholders.Monogram("The Matrix")); Assert.Equal("D", Placeholders.Monogram("Dune")); Assert.Equal("#", Placeholders.Monogram("!!!")); Assert.Equal("É", Placeholders.Monogram("épopée").Substring(0, 1).Replace("E", "É"));
        Assert.Equal(Placeholders.Hue("Dune"), Placeholders.Hue("Dune"));
        Assert.InRange(Placeholders.Hue("anything"), 0, 359);
        var (r, g, b) = Placeholders.Rgb(200); Assert.True(b > r);
    }

    [Fact]
    public void PostersComeFirstAndOrderIsKept()
    {
        var sorted = Placeholders.PosterFirst(new[] { "a-", "b+", "c-", "d+" }, s => s.EndsWith('+'));
        Assert.Equal(new[] { "b+", "d+", "a-", "c-" }, sorted);
    }

    [Fact]
    public async Task RetryTriesAgainWithGrowingPausesThenGivesUp()
    {
        var calls = 0; var pauses = new List<TimeSpan>();
        var got = await Retry.RunAsync<byte[]>(() => { calls++; return Task.FromResult<byte[]?>(calls < 3 ? null : new byte[] { 1 }); }, 3, null, t => { pauses.Add(t); return Task.CompletedTask; });
        Assert.NotNull(got); Assert.Equal(3, calls); Assert.Equal(new[] { 500.0, 1000.0 }, pauses.Select(p => p.TotalMilliseconds));
        calls = 0;
        Assert.Null(await Retry.RunAsync<byte[]>(() => { calls++; throw new HttpRequestException("x"); }, 3, null, _ => Task.CompletedTask));
        Assert.Equal(3, calls);
    }

    [Fact]
    public void MemoryCacheNeverExceedsItsBudgetAndDropsTheLeastRecentlyUsed()
    {
        var c = new ByteLru(100);
        c.Put("a", new byte[40]); c.Put("b", new byte[40]);
        Assert.True(c.TryGet("a", out _));                // a is now the most recent
        c.Put("c", new byte[40]);                         // b goes
        Assert.False(c.TryGet("b", out _)); Assert.True(c.TryGet("a", out _)); Assert.True(c.TryGet("c", out _));
        Assert.True(c.Bytes <= 100);
        c.Put("huge", new byte[500]); Assert.False(c.TryGet("huge", out _)); Assert.Equal(2, c.Count);
        c.Put("a", new byte[10]); Assert.Equal(50, c.Bytes);
    }
}

public class CastTests
{
    private sealed class Fetcher(Func<string, string> reply) : ITextFetcher
    {
        public List<string> Urls { get; } = new();
        public Task<string> FetchAsync(string url, CancellationToken ct = default) => FetchAsync(url, null, ct);
        public Task<string> FetchAsync(string url, IReadOnlyDictionary<string, string>? headers, CancellationToken ct = default, string method = "GET", string? body = null) { Urls.Add(url); return Task.FromResult(reply(url)); }
    }

    private static Item M(string id, string title, string group, int year = 2021, Kind kind = Kind.Movie) => new() { Id = id, Kind = kind, Title = title, Group = group, Year = year };

    private const string Credits = """{"cast":[{"id":11,"name":"Zendaya","character":"Chani","profile_path":"/z.jpg","order":0},{"id":12,"name":"No Photo","character":"","profile_path":null},{"id":11,"name":"Zendaya","character":"Dup"}]}""";
    private static string Reply(string url) => url.Contains("/search/movie") ? """{"results":[{"id":438631}]}""" : url.Contains("/credits") ? Credits
        : url.Contains("/search/person") ? """{"results":[{"id":5,"name":"Zendaya Coleman"},{"id":11,"name":"zendaya"}]}"""
        : """{"cast":[{"media_type":"movie","title":"Dune","release_date":"2021-10-22"},{"media_type":"movie","title":"Dune: Part Two","release_date":"2024-03-01"},{"media_type":"tv","name":"Euphoria","first_air_date":"2019-06-16"},{"media_type":"person","name":"x"},{"media_type":"movie","title":"Dune","release_date":"2021-10-22"}]}""";

    private static PrivacySnapshot Snap(List<Copy> lib) => Privacy.Snapshot(new PrivacyInput(new Dictionary<Kind, IReadOnlySet<string>> { [Kind.Movie] = new HashSet<string> { "Secret" } },
        new Dictionary<Kind, IReadOnlySet<string>>(), new Dictionary<Kind, IReadOnlySet<string>>(), false, false), Surface.Recommend, lib);

    [Fact]
    public void CreditsParseWithPhotoAndNoDuplicates()
    {
        var cast = TmdbCast.ParseCredits(Credits);
        Assert.Equal(2, cast.Count);
        Assert.Equal("https://image.tmdb.org/t/p/w185/z.jpg", cast[0].PhotoUrl); Assert.Equal("Chani", cast[0].Character);
        Assert.Null(cast[1].PhotoUrl); Assert.Null(cast[1].Character); Assert.Equal("NP", TmdbCast.Initials(cast[1].Name));
    }

    [Fact]
    public async Task CastIsLookedUpForVisibleTitlesAndNeverForRestrictedOnes()
    {
        var lib = new List<Copy> { new("A", M("1", "Dune (2021) 4K", "Movies")), new("A", M("2", "Secret Film", "Secret")), new("B", M("3", "Twin Film", "Open")), new("B", M("4", "Twin Film", "Secret")) };
        var snap = Snap(lib);
        var f = new Fetcher(Reply);
        var cast = await TmdbCast.CastOfAsync(f, "KEY", snap, lib[0]);
        Assert.Equal(2, cast!.Count);
        Assert.Contains("query=dune", f.Urls[0]); Assert.Contains("year=2021", f.Urls[0]);
        var g = new Fetcher(Reply);
        Assert.Null(await TmdbCast.CastOfAsync(g, "KEY", snap, lib[1]));
        Assert.Null(await TmdbCast.CastOfAsync(g, "KEY", snap, lib[2]));                  // its twin sits in a locked folder
        Assert.Empty(g.Urls);                                                             // nothing about them was sent
    }

    [Fact]
    public async Task PersonIsFoundByExactNameOnly()
    {
        var f = new Fetcher(Reply);
        var credits = await TmdbCast.FilmographyAsync(f, "KEY", new CastMember(0, "Zendaya", null, null));
        Assert.Contains(f.Urls, u => u.Contains("/person/11/combined_credits"));          // "Zendaya Coleman" is another person
        Assert.Equal(4, credits.Count);
        Assert.Null(TmdbCast.ParsePersonExact("""{"results":[{"id":5,"name":"Zendaya Coleman"}]}""", "Zendaya"));
        var byId = new Fetcher(Reply);
        await TmdbCast.FilmographyAsync(byId, "KEY", new CastMember(11, "Zendaya", null, null));
        Assert.DoesNotContain(byId.Urls, u => u.Contains("/search/person"));
    }

    [Fact]
    public void LibraryTitlesAppearOnceWithOtherVersionsFoldedInAndRestrictedOnesLeftOut()
    {
        var lib = new List<Copy>
        {
            new("A", M("1", "Dune (2021)", "English | General")), new("B", M("2", "Dune 2021 4K", "Hindi Dubbed")), new("B", M("3", "Dune", "Telugu")),
            new("A", M("4", "Dune: Part Two", "Secret", 2024)),                        // locked
            new("A", M("5", "Euphoria", "Shows", 2019, Kind.Series)),
        };
        var credits = new[] { new Credit("movie", "Dune", null, 2021), new Credit("movie", "Dune: Part Two", null, 2024), new Credit("tv", "Euphoria", null, 2019), new Credit("movie", "Dune", null, 2021) };
        var found = TmdbCast.InLibrary(credits, lib, Snap(lib), new CanonicalPick.Context("Telugu"));
        Assert.Equal(2, found.Count);
        Assert.Equal("B:3", found[0].Pick.Key); Assert.Equal(2, found[0].Others.Count);    // one card for Dune, the Telugu copy shown, the others folded in
        Assert.Equal("Euphoria", found[1].Pick.Item.Title);
        Assert.DoesNotContain(found, t => t.Pick.Item.Title.Contains("Part Two"));
    }
}
