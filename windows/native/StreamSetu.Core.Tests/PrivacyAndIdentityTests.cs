using StreamSetu.Core;
using StreamSetu.Core.SmartMix;
using Xunit;

namespace StreamSetu.Core.Tests;

public class PrivacyAndIdentityTests
{
    private static Item M(string id, string title, string group, int? year = 2020, Kind kind = Kind.Movie) => new() { Id = id, Kind = kind, Title = title, Group = group, Year = year, Logo = "x", Added = new DateTimeOffset(2026, 11, 1, 0, 0, 0, TimeSpan.Zero) };

    // Two playlists that are twins: A lists "English | General" and "Secret", B lists the same folders spelled differently.
    private static List<Copy> Library() => new()
    {
        new("A", M("1", "Dune (2021)", "English | General")),
        new("B", M("1", "Dune 2021 4K", "ENGLISH | GENERAL")),
        new("A", M("2", "Heat", "Secret")),
        new("B", M("2", "Heat", "Mixed")),                         // the twin copy of a locked title sits in an open folder
        new("A", M("3", "Alpha", "Mixed", 2019)),
        new("A", M("4", "Hidden Gem", "Hid")),
        new("B", M("5", "Adult Thing", "XXX Movies")),
        new("A", M("6", "Show One", "Shows", 2018, Kind.Series)),
    };

    private static PrivacyInput Input(bool kids = false, bool hideAdult = false, bool unlockSecret = false) => new(
        new Dictionary<Kind, IReadOnlySet<string>> { [Kind.Movie] = new HashSet<string> { "Secret" } },
        new Dictionary<Kind, IReadOnlySet<string>> { [Kind.Movie] = new HashSet<string> { "Hid" } },
        new Dictionary<Kind, IReadOnlySet<string>> { [Kind.Movie] = unlockSecret ? new HashSet<string> { "Secret" } : new HashSet<string>() },
        hideAdult, kids);

    private static IEnumerable<string> Ids(IEnumerable<Copy> c) => c.Select(x => x.Key).OrderBy(x => x, StringComparer.Ordinal);

    [Fact]
    public void HistoryKeepsHiddenButNotLocked()
    {
        var snap = Privacy.Snapshot(Input(), Surface.History, Library());
        Assert.Contains("A:4", Ids(snap.Filter(Library())));      // hidden folders are not a history rule
        Assert.DoesNotContain("A:2", Ids(snap.Filter(Library())));
        var unlocked = Privacy.Snapshot(Input(unlockSecret: true), Surface.History, Library());
        Assert.Contains("A:2", Ids(unlocked.Filter(Library())));   // unlocked with the PIN: history shows it again, nothing was deleted
    }

    [Fact]
    public void SearchDropsLockedHiddenAndAdult()
    {
        var snap = Privacy.Snapshot(Input(hideAdult: true), Surface.Search, Library());
        var found = Ids(Privacy.Search(snap, Library(), "a"));
        Assert.DoesNotContain("A:2", found); Assert.DoesNotContain("A:4", found); Assert.DoesNotContain("B:5", found);
        Assert.Contains("A:3", found);
        Assert.Empty(Privacy.Search(snap, Library(), "hidden gem"));
    }

    [Fact]
    public void KidsAlwaysExcludeAdultFolders()
    {
        var kids = Privacy.Snapshot(Input(kids: true), Surface.Search, Library());
        Assert.False(kids.ItemOk(Library()[6]));
        var grown = Privacy.Snapshot(Input(), Surface.Search, Library());
        Assert.True(grown.ItemOk(Library()[6]));
    }

    [Fact]
    public void RecommendStaysRestrictedEvenWhileUnlocked()
    {
        var snap = Privacy.Snapshot(Input(unlockSecret: true), Surface.Recommend, Library());
        Assert.False(snap.ItemOk(Library()[2]));
        Assert.Contains("Secret", snap.Excluded(Kind.Movie));
    }

    [Fact]
    public void ATitleIsRestrictedIfAnyTwinCopyIs()
    {
        var snap = Privacy.Snapshot(Input(), Surface.Recommend, Library());
        Assert.False(snap.ItemOk(Library()[3]));                   // B's "Heat" is in an open folder but A's copy is locked
        Assert.True(snap.ItemOk(Library()[4]));
    }

    [Fact]
    public void LocksPropagateToSameNamedFoldersOfOtherPlaylists()
    {
        var input = new PrivacyInput(new Dictionary<Kind, IReadOnlySet<string>> { [Kind.Movie] = new HashSet<string> { "English | General" } },
            new Dictionary<Kind, IReadOnlySet<string>>(), new Dictionary<Kind, IReadOnlySet<string>>(), false, false);
        var snap = Privacy.Snapshot(input, Surface.Recommend, Library());
        Assert.Contains("ENGLISH | GENERAL", snap.Excluded(Kind.Movie));
        Assert.False(snap.ItemOk(Library()[1]));
    }

    [Fact]
    public void CountsShowNoCountForALockedFolder()
    {
        var counts = Privacy.FolderCounts(Input(), Kind.Movie, Library());
        var secret = Assert.Single(counts, c => c.Name == "Secret");
        Assert.True(secret.Locked); Assert.Null(secret.Count);
        Assert.DoesNotContain(counts, c => c.Name == "Hid");
        Assert.Equal(2, counts.Single(c => c.Name == "Mixed").Count);
        Assert.DoesNotContain(Privacy.FolderCounts(Input(kids: true), Kind.Movie, Library()), c => c.Name == "Secret");
        Assert.Equal(1, Privacy.FolderCounts(Input(unlockSecret: true), Kind.Movie, Library()).Single(c => c.Name == "Secret").Count);
    }

    [Fact]
    public void GenresAndYearsNeverComeFromRestrictedFolders()
    {
        var lib = new List<Copy> { new("A", M("1", "One", "Open", 2001)), new("A", M("2", "Two", "Secret", 1999)) };
        var snap = Privacy.Snapshot(Input(), Surface.Recommend, lib);
        Assert.Equal(new[] { 2001 }, Privacy.Years(snap, Kind.Movie, lib));
        Assert.Equal(new[] { "drama" }, Privacy.Genres(snap, Kind.Movie, lib, i => i.Id == "1" ? "drama" : "horror"));
    }

    [Fact]
    public void SimilarNeverNamesRestrictedTitles()
    {
        var lib = new List<Copy> { new("A", M("1", "Star Quest", "Open")), new("A", M("2", "Star Quest Returns", "Secret")), new("A", M("3", "Star Wars", "Open")) };
        var snap = Privacy.Snapshot(Input(), Surface.Search, lib);
        var sim = Privacy.Similar(snap, lib[0], lib);
        Assert.DoesNotContain(sim, c => c.Item.Id == "2");
        Assert.Contains(sim, c => c.Item.Id == "3");
    }

    [Fact]
    public void CacheIsKeyedByWhatWasRestricted()
    {
        var cache = new RestrictedCache<int>();
        var open = Privacy.Snapshot(PrivacyInput.Open, Surface.Recommend, Library());
        var locked = Privacy.Snapshot(Input(), Surface.Recommend, Library());
        Assert.NotEqual(open.Revision, locked.Revision);
        Assert.Equal(1, cache.GetOrBuild("home", open.Revision, () => 1));
        Assert.Equal(2, cache.GetOrBuild("home", locked.Revision, () => 2));   // never the shelf built in the other state
        cache.Purge(); Assert.Equal(0, cache.Count);
    }

    [Fact]
    public void PlaylistDataIsNeverChanged()
    {
        var lib = Library(); var before = lib.Select(c => (c.Key, c.Item)).ToList();
        var snap = Privacy.Snapshot(Input(), Surface.Recommend, lib);
        _ = snap.Filter(lib).ToList(); _ = Privacy.FolderCounts(Input(), Kind.Movie, lib);
        _ = SmartMixCandidates.Build(lib, snap, DateTimeOffset.UtcNow, _ => new WatchInfo());
        Assert.Equal(before.Count, lib.Count);
        for (var i = 0; i < lib.Count; i++) { Assert.Same(before[i].Item, lib[i].Item); Assert.Equal(before[i].Key, lib[i].Key); }
    }

    [Fact]
    public void FolderPrefsLockEveryFamilyMember()
    {
        var dir = Path.Combine(Path.GetTempPath(), "ss-priv-" + Guid.NewGuid().ToString("N"));
        var prefs = new FolderPrefs(new LocalStore(dir));
        prefs.SetLockFamily("movies", "English | General", "1234", new[] { "English | General", "ENGLISH | GENERAL", "Other" });
        Assert.Equal(new[] { "ENGLISH | GENERAL", "English | General" }, prefs.LockedGroups("movies").OrderBy(x => x, StringComparer.Ordinal));
        prefs.HideFamily("movies", "Other", true, new[] { "Other" });
        Assert.True(prefs.IsHidden("movies", "Other"));
        Directory.Delete(dir, true);
    }

    // ---- identity
    [Fact]
    public void IdentityKeysMatchTwinsAcrossLanguageAndQuality()
    {
        Assert.Equal(IdentityKey.Make("The Dune (2021) 4K"), IdentityKey.Make("Dune HD Hindi"));
        Assert.Equal("matrix", IdentityKey.Make("The Matrix (1999) FHD"));
        Assert.Equal("hd", IdentityKey.Make("HD"));                           // never collapses to nothing
        Assert.Equal(IdentityKey.Make("Amélie"), IdentityKey.Make("amelie"));
        Assert.Equal("tom jerry", IdentityKey.Make("Tom and Jerry"));
    }

    [Fact]
    public void DerivesLanguageQualityAndCam()
    {
        var d = IdentityDerive.Derive("Kalki 2898 AD (Telugu) 4K", "Movies | Hindi Dubbed", null, Kind.Movie);
        Assert.Equal("Telugu", d.Language); Assert.Equal(5, d.QualityRank); Assert.False(d.IsCam);
        Assert.Equal("movie|movies hindi dubbed", d.FolderKey);
        Assert.Equal("Hindi", IdentityDerive.Language("Leo", "Hindi Dubbed"));
        Assert.Equal("Hindi", IdentityDerive.Language("Leo", "English Subtitles Hindi"));
        var cam = IdentityDerive.Derive("New Film HDCAM", null, 2026, Kind.Movie);
        Assert.True(cam.IsCam); Assert.Equal(0, cam.QualityRank);
        Assert.Equal(2024, IdentityDerive.Year(null, "Film 2024 HD"));
    }

    [Fact]
    public void CanonicalPickIsDeterministicAndKeepsAlternatives()
    {
        var ranking = PreferredSource.Ranking(new[] { new SourceHealth("b", true, "ok", null, 1), new SourceHealth("a", true, "ok", null, 0) });
        var ctx = new CanonicalPick.Context("Telugu", ranking);
        var members = new[]
        {
            new IdentityMember("x1", "a", "Hindi", 5, false, 2020, 5), new IdentityMember("x2", "b", "Telugu", 3, false, 2020, 1),
            new IdentityMember("x3", "a", "Telugu", 3, false, 2020, 1), new IdentityMember("x4", "a", "Telugu", 0, true, 2020, 9),
        };
        Assert.Equal("x3", CanonicalPick.Pick(members, ctx)!.ItemId);                 // language first, then quality, then the preferred playlist
        Assert.Equal(new[] { "x3", "x2", "x4", "x1" }, CanonicalPick.Ordered(members.AsEnumerable().Reverse(), ctx).Select(m => m.ItemId));
        Assert.Equal(3, CanonicalPick.Alternatives(members, ctx).Count);
        Assert.Equal("x1", CanonicalPick.Pick(members, new CanonicalPick.Context(null, ranking))!.ItemId);
    }

    [Fact]
    public void PreferredSourcePrefersHealthyEnabledPlaylists()
    {
        var now = new DateTimeOffset(2026, 11, 21, 0, 0, 0, TimeSpan.Zero);
        var r = PreferredSource.Ranking(new[]
        {
            new SourceHealth("old", true, "ok", now.AddDays(-30), 0), new SourceHealth("fresh", true, "ok", now.AddDays(-1), 5),
            new SourceHealth("off", false, "ok", now, 0), new SourceHealth("bad", true, "failed", now, 0),
        }, null, now);
        Assert.True(r["fresh"] < r["old"]); Assert.True(r["fresh"] < r["bad"]); Assert.Equal(3, r["off"]);
        Assert.Equal(0, PreferredSource.Ranking(new[] { new SourceHealth("a", true, "ok", now.AddDays(-99), 0) }, null, now)["a"]);
    }

    [Fact]
    public void RestrictedTitlesNeverReachShownHistory()
    {
        var lib = Library();
        var snap = Privacy.Snapshot(Input(), Surface.Recommend, lib);
        var cands = SmartMixCandidates.Build(lib, snap, new DateTimeOffset(2026, 11, 21, 0, 0, 0, TimeSpan.Zero), _ => new WatchInfo());
        var state = new SmartMixState();
        var res = SmartMixEngine.Run(cands, new SmartMixContext("p", "2026-11-21"), new[] { "for-you", "hero" }, state, true);
        var shown = res.Values.SelectMany(r => r.Items).Select(c => c.Key).ToHashSet();
        Assert.DoesNotContain("heat", shown);                                      // the twin rule removed both copies
        Assert.DoesNotContain("hidden gem", shown);
        Assert.DoesNotContain(state.Get("p", "for-you").Rows, r => r.IdentityKey is "heat" or "hidden gem");
        state.Purge("p"); Assert.Empty(state.Get("p", "for-you").Rows);
    }
}

public class OtherVersionsTests
{
    private static Item M(string id, string title, string group, int year = 2021) => new() { Id = id, Kind = Kind.Movie, Title = title, Group = group, Year = year };

    [Fact]
    public void OffersOtherLanguagesAndQualitiesBestFirstWithoutRestrictedOnes()
    {
        var lib = new List<Copy>
        {
            new("A", M("1", "Dune (2021)", "English | General")),
            new("A", M("2", "Dune 2021 4K", "Hindi Dubbed")),
            new("B", M("3", "Dune", "Telugu")),
            new("B", M("4", "Dune HDCAM", "Secret")),            // in a locked folder: never offered
            new("B", M("5", "Dunes of Time", "Telugu")),           // another title
            new("B", M("6", "Dune", "Telugu", 1984)),              // a remake decades earlier
        };
        var input = new PrivacyInput(new Dictionary<Kind, IReadOnlySet<string>> { [Kind.Movie] = new HashSet<string> { "Secret" } }, new Dictionary<Kind, IReadOnlySet<string>>(), new Dictionary<Kind, IReadOnlySet<string>>(), false, false);
        var snap = Privacy.Snapshot(input, Surface.Search, lib);
        var others = OtherVersions.For(snap, lib[0], lib, new CanonicalPick.Context("Telugu"));
        Assert.Equal(new[] { "B:3", "A:2" }, others.Select(o => o.Copy.Key));       // the preferred language first, then the better picture
        Assert.Equal("4K", OtherVersions.QualityLabel(others[1].QualityRank));
        Assert.Equal("Hindi", others[1].Language);
        Assert.Equal(6, lib.Count);                                                  // nothing was removed or merged
    }
}
