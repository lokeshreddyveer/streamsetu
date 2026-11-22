namespace StreamSetu.Core.SmartMix;

public sealed record HomeShelf(string Id, string Title, IReadOnlyList<Copy> Items);

/// <param name="Hero">The pictures at the top (a backdrop when the playlist has one, else the poster).</param>
/// <param name="TmdbStatus">"off", "noCache", "purged", "expired" or "active": for About and the Settings line, never shown on a shelf.</param>
public sealed record HomeContent(IReadOnlyList<Copy> Hero, IReadOnlyList<HomeShelf> Shelves, string TmdbStatus);

public sealed record HomeInputs(
    IReadOnlyCollection<Copy> Copies, PrivacyInput Privacy, string DayKey, string? PreferredLanguage, TrendingInput? Tmdb,
    Func<Copy, WatchInfo> Watch, IReadOnlyDictionary<string, int>? SourceRank = null);

/// <summary>The Home screen's shelves, from the engine. Everything is built from the always-restricted baseline: locked, hidden and adult-Kids folders (and any title with a copy there) never appear,
/// even while the person has unlocked a folder with the PIN. Continue Watching is not part of this and is never filtered here.</summary>
public static class HomeBuilder
{
    public static readonly string[] GlobalShelves = { "hero", "top-week", "trending-library", "for-you", "rediscover", "lang-pref" };

    public static (Dictionary<string, Copy> ById, List<Cand> Candidates, PrivacySnapshot Snapshot) Candidates(HomeInputs input)
    {
        var snap = Privacy.Snapshot(input.Privacy, Surface.Recommend, input.Copies);
        var dayStart = DayStart(input.DayKey);
        var cands = SmartMixCandidates.Build(input.Copies, snap, dayStart, input.Watch, input.SourceRank);
        var byId = new Dictionary<string, Copy>();
        foreach (var c in input.Copies) byId[c.StoreKey] = c;
        return (byId, cands, snap);
    }

    public static DateTimeOffset DayStart(string dayKey) => new(int.Parse(dayKey[..4]), int.Parse(dayKey[5..7]), int.Parse(dayKey[8..10]), 0, 0, 0, TimeSpan.Zero);

    /// <summary>What the person watches most: the languages, folders and decades of the titles they watched.</summary>
    public static Affinity AffinityOf(IEnumerable<Cand> watched)
    {
        var list = watched.ToList();
        static List<string> Top(IEnumerable<string?> values, int n) => values.Where(v => v is not null).GroupBy(v => v!).OrderByDescending(g => g.Count()).ThenBy(g => g.Key, StringComparer.Ordinal).Take(n).Select(g => g.Key).ToList();
        var decades = list.Where(c => c.Year is not null).GroupBy(c => c.Year!.Value / 10 * 10).OrderByDescending(g => g.Count()).ThenByDescending(g => g.Key).Take(2).Select(g => g.Key).ToList();
        return new Affinity(Top(list.Select(c => c.Lang), 3), Top(list.Select(c => c.Folder), 5), Array.Empty<string>(), decades);
    }

    public static HomeContent Build(HomeInputs input, SmartMixState state, string profile, long refreshCounter, bool commit)
    {
        var (byId, cands, _) = Candidates(input);
        var affinity = AffinityOf(cands.Where(c => c.Watched));
        var anyWatched = cands.Any(c => c.Watched);
        var lang = string.IsNullOrWhiteSpace(input.PreferredLanguage) ? null : input.PreferredLanguage!.Trim();
        var ctx = new SmartMixContext(profile, input.DayKey, refreshCounter, lang, affinity, null, input.Tmdb);
        var ids = GlobalShelves.Where(s => s switch { "for-you" or "rediscover" => anyWatched, "lang-pref" => lang is not null, _ => true }).ToList();
        var res = SmartMixEngine.Run(cands, ctx, ids, state, commit);

        List<Copy> Of(string shelf) => res.TryGetValue(shelf, out var r) && !r.Diag.Hidden ? r.Items.Select(c => byId[c.Id]).ToList() : new List<Copy>();
        var shelves = new List<HomeShelf>();
        void Add(string id, string title) { var items = Of(id); if (items.Count > 0) shelves.Add(new HomeShelf(id, title, items)); }
        Add("top-week", "Top This Week");
        Add("trending-library", "Trending");
        Add("for-you", "Because You Watched");
        Add("rediscover", "Rediscover");
        if (lang is not null) Add("lang-pref", lang);
        return new HomeContent(Of("hero"), shelves, SmartMixEngine.TrendingStatus(input.Tmdb));
    }

    /// <summary>One folder's row: up to 12 titles, through the same restricted baseline. A folder that is locked or hidden has no row (its name and lock are shown by the caller, without a count).</summary>
    public static List<Copy> FolderRow(HomeInputs input, SmartMixState state, string profile, long refreshCounter, Kind kind, string folderName)
    {
        var (byId, cands, snap) = Candidates(input);
        if (!snap.FolderOk(kind, folderName)) return new List<Copy>();
        var key = FolderKeyOf(kind, folderName);
        var ctx = new SmartMixContext(profile, input.DayKey, refreshCounter, null, Affinity.None, null, null);
        var res = SmartMixEngine.Run(cands.Where(c => c.Kind == (kind == Kind.Series ? "series" : "movie")).ToList(), ctx, new[] { "folder:" + key }, state, false);
        return res["folder:" + key].Items.Select(c => byId[c.Id]).ToList();
    }

    public static string FolderKeyOf(Kind kind, string folderName) => kind.ToString().ToLowerInvariant() + "|" + IdentityKey.Normalize(folderName);
}
