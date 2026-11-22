using System.Text.Json;
using StreamSetu.Core;
using StreamSetu.Core.SmartMix;
using Xunit;

namespace StreamSetu.Core.Tests;

public class HomeAndTmdbTests
{
    private static Item M(string id, string title, string group, int year = 2020, string? logo = "x", Kind kind = Kind.Movie, int addedDaysAgo = 10)
        => new() { Id = id, Kind = kind, Title = title, Group = group, Year = year, Logo = logo, Added = new DateTimeOffset(2026, 11, 21, 0, 0, 0, TimeSpan.Zero).AddDays(-addedDaysAgo) };

    private static List<Copy> Library()
    {
        var l = new List<Copy>();
        for (var i = 0; i < 40; i++) l.Add(new Copy("A", M("m" + i, "Movie Number " + i + " Part", i % 2 == 0 ? "English | 4K" : "Telugu", 2010 + i % 15, addedDaysAgo: i * 5)));
        l.Add(new Copy("A", M("x1", "Locked Film", "Secret")));
        l.Add(new Copy("B", M("x1", "Locked Film", "Open Twin")));
        return l;
    }

    private static HomeInputs Inputs(PrivacyInput? p = null, Func<Copy, WatchInfo>? w = null, string? lang = null, TrendingInput? tmdb = null)
        => new(Library(), p ?? PrivacyInput.Open, "2026-11-21", lang, tmdb, w ?? (_ => new WatchInfo()));

    private static PrivacyInput LockSecret(bool unlocked = false) => new(
        new Dictionary<Kind, IReadOnlySet<string>> { [Kind.Movie] = new HashSet<string> { "Secret" } }, new Dictionary<Kind, IReadOnlySet<string>>(),
        new Dictionary<Kind, IReadOnlySet<string>> { [Kind.Movie] = unlocked ? new HashSet<string> { "Secret" } : new HashSet<string>() }, false, false);

    [Fact]
    public void HomeHasHeroAndShelvesWithoutAnythingRestricted()
    {
        var home = HomeBuilder.Build(Inputs(LockSecret(unlocked: true)), new SmartMixState(), "p", 0, false);   // unlocked with the PIN, still never on Home
        Assert.NotEmpty(home.Hero);
        var all = home.Hero.Concat(home.Shelves.SelectMany(s => s.Items));
        Assert.DoesNotContain(all, c => c.Item.Id == "x1");
        Assert.Contains(home.Shelves, s => s.Title == "Top This Week");
        Assert.All(home.Shelves, s => Assert.InRange(s.Items.Count, 1, 14));
        Assert.Equal("off", home.TmdbStatus);
    }

    [Fact]
    public void BecauseYouWatchedAndRediscoverNeedHistoryAndLanguageShelfNeedsAPreference()
    {
        var none = HomeBuilder.Build(Inputs(), new SmartMixState(), "p", 0, false);
        Assert.DoesNotContain(none.Shelves, s => s.Title is "Because You Watched" or "Rediscover" or "Telugu");
        var watched = HomeBuilder.Build(Inputs(w: c => c.Item.Id is "m0" or "m1" or "m2" ? new WatchInfo(true, true, 60) : new WatchInfo(), lang: "Telugu"), new SmartMixState(), "p", 0, false);
        Assert.Contains(watched.Shelves, s => s.Title == "Because You Watched");
        Assert.Contains(watched.Shelves, s => s.Title == "Rediscover");
        Assert.Contains(watched.Shelves, s => s.Title == "Telugu");
    }

    [Fact]
    public void ReshuffleChangesTheArrangementButTheSameCounterRepeatsIt()
    {
        var a = HomeBuilder.Build(Inputs(), new SmartMixState(), "p", 0, false);
        var b = HomeBuilder.Build(Inputs(), new SmartMixState(), "p", 0, false);
        var c = HomeBuilder.Build(Inputs(), new SmartMixState(), "p", 1, false);
        Assert.Equal(a.Hero.Select(x => x.Key), b.Hero.Select(x => x.Key));
        Assert.NotEqual(a.Shelves.SelectMany(s => s.Items).Select(x => x.Key), c.Shelves.SelectMany(s => s.Items).Select(x => x.Key));
    }

    [Fact]
    public void FolderRowNeverHoldsRestrictedTitlesAndALockedFolderHasNoRow()
    {
        var row = HomeBuilder.FolderRow(Inputs(LockSecret()), new SmartMixState(), "p", 0, Kind.Movie, "English | 4K");
        Assert.InRange(row.Count, 1, 12);
        Assert.All(row, c => Assert.Equal("English | 4K", c.Item.Group));
        Assert.Empty(HomeBuilder.FolderRow(Inputs(LockSecret()), new SmartMixState(), "p", 0, Kind.Movie, "Secret"));
        Assert.Empty(HomeBuilder.FolderRow(Inputs(LockSecret()), new SmartMixState(), "p", 0, Kind.Movie, "Open Twin"));     // its twin sits in the locked folder
    }

    [Fact]
    public void StoreKeepsHistoryAndCounterAndResetsTheCounterOnANewDay()
    {
        var dir = Path.Combine(Path.GetTempPath(), "ss-mix-" + Guid.NewGuid().ToString("N"));
        var store = new SmartMixStore(new LocalStore(dir)).Open("2026-11-21");
        var home = HomeBuilder.Build(Inputs(), store.State, SmartMixStore.ProfileKey, store.Refresh, true);
        store.Reshuffle(); store.Save();
        var again = new SmartMixStore(new LocalStore(dir)).Open("2026-11-21");
        Assert.Equal(1, again.Refresh);
        Assert.NotEmpty(again.State.Get(SmartMixStore.ProfileKey, "hero").Rows);
        Assert.Equal(0, new SmartMixStore(new LocalStore(dir)).Open("2026-11-22").Refresh);
        again.Purge(); Assert.Empty(again.State.Get(SmartMixStore.ProfileKey, "hero").Rows);
        Assert.NotEmpty(home.Hero);
        Directory.Delete(dir, true);
    }

    [Fact]
    public void FolderNamesShowAcronymsInCapitalsAndCountsInBrackets()
    {
        Assert.Equal("English · 4K", FolderNaming.Pretty("English | 4k"));
        Assert.Equal("Movies · FHD · hdr".Replace("hdr", "HDR"), FolderNaming.Pretty("Movies | fhd | hdr"));
        Assert.Equal("(1,058)", FolderNaming.CountText(1058));
        Assert.Equal("", FolderNaming.CountText(null));
        Assert.Equal("2021 · Drama", FolderNaming.TileLine(2021, "Drama"));
        Assert.Equal("2021", FolderNaming.TileLine(2021, null));
        Assert.Equal("", FolderNaming.TileLine(null, null));
    }

    // ---- TMDB
    private sealed class FakeFetcher(Func<string, string> reply) : ITextFetcher
    {
        public List<string> Urls { get; } = new();
        public List<IReadOnlyDictionary<string, string>?> Headers { get; } = new();
        public Task<string> FetchAsync(string url, CancellationToken ct = default) => FetchAsync(url, null, ct);
        public Task<string> FetchAsync(string url, IReadOnlyDictionary<string, string>? headers, CancellationToken ct = default, string method = "GET", string? body = null)
        { Urls.Add(url); Headers.Add(headers); return Task.FromResult(reply(url)); }
    }

    private const string MovieJson = """{"results":[{"title":"Dune: Part Two","original_title":"Dune: Part Two","release_date":"2024-02-27"},{"title":"Wicked","release_date":"2024-11-20"}]}""";
    private const string TvJson = """{"results":[{"name":"Shōgun","original_name":"Shōgun","first_air_date":"2024-02-27"}]}""";

    private static string Reply(string url) => url.Contains("/movie/") ? MovieJson : TvJson;

    [Fact]
    public void ParseAndInterleaveGiveOneRankForBothKinds()
    {
        var movies = Tmdb.Parse(MovieJson, "movie"); var tv = Tmdb.Parse(TvJson, "tv");
        Assert.Equal(2, movies.Count); Assert.Equal(2024, movies[0].Year); Assert.Equal("Shōgun", tv[0].Orig);
        var all = Tmdb.Interleave(movies, tv);
        Assert.Equal(new[] { "Dune: Part Two", "Shōgun", "Wicked" }, all.Select(e => e.Title));
        Assert.Equal(new long[] { 1, 2, 3 }, all.Select(e => e.Rank));
    }

    [Fact]
    public async Task NothingIsRequestedWithoutThePersonsOwnKeyOrWhenSwitchedOff()
    {
        var dir = Path.Combine(Path.GetTempPath(), "ss-tmdb-" + Guid.NewGuid().ToString("N"));
        var store = new LocalStore(dir); var f = new FakeFetcher(Reply); var now = DateTimeOffset.UtcNow;
        Assert.Null(await Tmdb.RefreshAsync(store, f, null, true, now));
        Assert.Null(await Tmdb.RefreshAsync(store, f, "  ", true, now));
        Assert.Null(await Tmdb.RefreshAsync(store, f, "KEY", false, now));
        Assert.Empty(f.Urls);
        Directory.Delete(dir, true);
    }

    [Fact]
    public async Task RefreshFetchesOncePerDayKeepsOldCacheOnFailureAndPurgesAfter180Days()
    {
        var dir = Path.Combine(Path.GetTempPath(), "ss-tmdb-" + Guid.NewGuid().ToString("N"));
        var store = new LocalStore(dir); var f = new FakeFetcher(Reply); var now = new DateTimeOffset(2026, 11, 21, 12, 0, 0, TimeSpan.Zero);
        var c = await Tmdb.RefreshAsync(store, f, "abc", true, now);
        Assert.Equal(3, c!.Entries.Count); Assert.Equal(2, f.Urls.Count);
        Assert.Contains("api_key=abc", f.Urls[0]);
        await Tmdb.RefreshAsync(store, f, "abc", true, now.AddHours(2));
        Assert.Equal(2, f.Urls.Count);                                                       // fresh enough: no new request
        var broken = new FakeFetcher(_ => throw new HttpRequestException("down"));
        var kept = await Tmdb.RefreshAsync(store, broken, "abc", true, now.AddDays(2));
        Assert.Equal(3, kept!.Entries.Count);                                                // failure keeps the old list
        Assert.Equal("expired", SmartMixEngine.TrendingStatus(new TrendingInput(true, true, Tmdb.ForEngine(kept, now.AddDays(45)))));
        Assert.Null(await Tmdb.RefreshAsync(store, new FakeFetcher(_ => throw new HttpRequestException("down")), "abc", true, now.AddDays(181)));
        Assert.Null(Tmdb.Load(store));                                                       // older than 180 days: deleted
        Assert.Null(await Tmdb.RefreshAsync(store, f, "abc", false, now)); Assert.Null(Tmdb.Load(store));
        Directory.Delete(dir, true);
    }

    [Fact]
    public async Task AV4TokenGoesInAHeaderNotInTheAddress()
    {
        var dir = Path.Combine(Path.GetTempPath(), "ss-tmdb-" + Guid.NewGuid().ToString("N"));
        var f = new FakeFetcher(Reply);
        await Tmdb.RefreshAsync(new LocalStore(dir), f, "eyJabc.def", true, DateTimeOffset.UtcNow);
        Assert.DoesNotContain("eyJ", f.Urls[0]);
        Assert.Equal("Bearer eyJabc.def", f.Headers[0]!["Authorization"]);
        Directory.Delete(dir, true);
    }

    [Fact]
    public async Task TrendingFromCacheOrdersTopThisWeekWhenEnoughTitlesMatch()
    {
        var lib = Library();
        var entries = lib.Take(8).Select((c, i) => new TrendingEntry(i + 1, "movie", c.Item.Title, null, c.Item.Year)).ToList();
        var tmdb = new TrendingInput(true, true, new TrendingCache(2, entries));
        var home = HomeBuilder.Build(Inputs(tmdb: tmdb), new SmartMixState(), "p", 0, false);
        Assert.Equal("active", home.TmdbStatus);
        var top = home.Shelves.First(s => s.Id == "top-week");
        Assert.Equal(lib.Take(8).Select(c => c.StoreKey), top.Items.Take(8).Select(c => c.StoreKey));
        await Task.CompletedTask;
    }
}
