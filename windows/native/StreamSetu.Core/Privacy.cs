using System.Text.RegularExpressions;

namespace StreamSetu.Core;

/// <summary>One title as it sits in one playlist. Playlist data is only ever read here: nothing is deleted, merged, renamed or re-keyed.</summary>
public sealed record Copy(string PlaylistId, Item Item)
{
    public string Key => PlaylistId + ":" + Item.Id;
    /// <summary>The key favourites, progress and watched marks use: the connection, then the title (see AppServices.KeyOf).</summary>
    public string StoreKey => PlaylistId + "|" + Item.Id;
}

/// <summary>Who may see which folder: the three surfaces ask differently.
/// History (what was already watched): locked folders not unlocked with the PIN, and adult folders while adult content is hidden (always in a Kids profile). Nothing is deleted.
/// Search (search, suggestions, similar titles, versions, counts): the same plus folders the person hid.
/// Recommend (the hero, shelves, folder rows, genre/year lists, caches): the strictest. Locked folders stay out even after an unlock (what is built then is cached and shown later),
/// same-named folders of other playlists are covered, and a title is out when ANY copy of it (another language, another playlist) sits in a restricted folder.</summary>
public enum Surface { History, Search, Recommend }

public sealed record PrivacyInput(
    IReadOnlyDictionary<Kind, IReadOnlySet<string>> Locked,
    IReadOnlyDictionary<Kind, IReadOnlySet<string>> Hidden,
    IReadOnlyDictionary<Kind, IReadOnlySet<string>> UnlockedNow,
    bool HideAdult,
    bool Kids)
{
    private static readonly IReadOnlySet<string> None = new HashSet<string>();
    public static PrivacyInput Open => new(new Dictionary<Kind, IReadOnlySet<string>>(), new Dictionary<Kind, IReadOnlySet<string>>(), new Dictionary<Kind, IReadOnlySet<string>>(), false, false);
    internal static IReadOnlySet<string> Of(IReadOnlyDictionary<Kind, IReadOnlySet<string>> d, Kind k) => d.TryGetValue(k, out var s) ? s : None;
}

public static class FolderFamily
{
    private static readonly Regex Adult = new(@"(^|[^a-z])(xxx|adult|adults|porn|erotic|18\+|sex|playboy|hustler)([^a-z]|$)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    public static bool IsAdultName(string name) => Adult.IsMatch(name);

    /// <summary>"ENGLISH | GENERAL" and "English | General" are one family, in every playlist.</summary>
    public static string Of(string name) => IdentityKey.Normalize(name);

    /// <summary>The folders of other playlists (or spelled differently) that are the same folder to the person, the folder itself included.</summary>
    public static List<string> Siblings(string name, IEnumerable<string> allNames)
    {
        var fam = Of(name);
        return allNames.Where(n => Of(n) == fam).Append(name).Distinct().ToList();
    }
}

/// <summary>Keys (and years) of the titles that sit in a restricted folder.</summary>
public sealed class TwinIndex
{
    private readonly Dictionary<string, List<int?>> _byKey = new();
    public int Size => _byKey.Count;

    public void Add(string title, int? year)
    {
        var key = KeyOf(title);
        if (!_byKey.TryGetValue(key, out var l)) _byKey[key] = l = new List<int?>(1);
        l.Add(IdentityDerive.Year(year, title));
    }

    private static string KeyOf(string title) { var k = IdentityKey.Make(title); return k.Length > 0 ? k : title.Trim().ToLowerInvariant(); }

    /// <summary>True when this title is a copy of one in a restricted folder. A year apart counts as the same: when in doubt the title is held back.</summary>
    public bool Covers(string title, int? year)
    {
        var key = KeyOf(title);
        if (!_byKey.TryGetValue(key, out var years)) return false;
        var y = IdentityDerive.Year(year, title);
        return years.Any(o => y is null || o is null ? (y is null && o is null) || key.Contains(' ') : Math.Abs(y.Value - o.Value) <= 1);
    }
}

/// <summary>A frozen view for one computation: ask it about many items without more reads.</summary>
public sealed class PrivacySnapshot
{
    private readonly Dictionary<Kind, HashSet<string>> _excluded = new();
    private readonly Dictionary<Kind, TwinIndex> _twins = new();
    public Surface Surface { get; }
    /// <summary>Changes whenever what is restricted changes: key every cache built from this surface with it.</summary>
    public string Revision { get; }

    internal PrivacySnapshot(Surface surface, Dictionary<Kind, HashSet<string>> excluded, Dictionary<Kind, TwinIndex> twins, string revision)
    {
        Surface = surface; _excluded = excluded; _twins = twins; Revision = revision;
    }

    public bool FolderOk(Kind kind, string? group) => group is null || !(_excluded.TryGetValue(kind, out var s) && s.Contains(group));
    public IReadOnlySet<string> Excluded(Kind kind) => _excluded.TryGetValue(kind, out var s) ? s : new HashSet<string>();
    public bool TitleOk(Kind kind, string? group, string title, int? year) => FolderOk(kind, group) && !(_twins.TryGetValue(kind, out var t) && t.Covers(title, year));
    public bool ItemOk(Item item) => TitleOk(item.Kind, item.Group, item.Title, item.Year);
    public bool ItemOk(Copy copy) => ItemOk(copy.Item);
    public IEnumerable<Copy> Filter(IEnumerable<Copy> copies) => copies.Where(ItemOk);
    public IEnumerable<Item> Filter(IEnumerable<Item> items) => items.Where(ItemOk);
}

public static class Privacy
{
    /// <summary>Builds the snapshot for one surface from every playlist's copies (read only).</summary>
    public static PrivacySnapshot Snapshot(PrivacyInput input, Surface surface, IReadOnlyCollection<Copy> all)
    {
        var excluded = new Dictionary<Kind, HashSet<string>>();
        var twins = new Dictionary<Kind, TwinIndex>();
        var rev = new List<string>();
        foreach (var kind in new[] { Kind.Movie, Kind.Series, Kind.Live })
        {
            var groups = all.Where(c => c.Item.Kind == kind).Select(c => c.Item.Group).Distinct().ToList();
            var locked = PrivacyInput.Of(input.Locked, kind);
            var lockedNow = surface == Surface.Recommend ? locked : locked.Where(g => !PrivacyInput.Of(input.UnlockedNow, kind).Contains(g)).ToHashSet();
            var adult = input.HideAdult || input.Kids ? groups.Where(FolderFamily.IsAdultName) : Enumerable.Empty<string>();
            var hidden = surface == Surface.History ? Enumerable.Empty<string>() : PrivacyInput.Of(input.Hidden, kind);
            var ex = lockedNow.Concat(adult).Concat(hidden).ToHashSet();
            if (surface == Surface.Recommend)
            {
                // A folder with the same name in another playlist is the same folder to the person: covered whether or not it was marked by hand.
                var families = ex.Select(FolderFamily.Of).ToHashSet();
                foreach (var g in groups) if (families.Contains(FolderFamily.Of(g))) ex.Add(g);
                if (ex.Count > 0 && kind != Kind.Live)
                {
                    var idx = new TwinIndex();
                    foreach (var c in all) if (c.Item.Kind == kind && ex.Contains(c.Item.Group)) idx.Add(c.Item.Title, c.Item.Year);
                    twins[kind] = idx;
                }
            }
            excluded[kind] = ex;
            rev.Add(kind + "=" + string.Join(",", ex.OrderBy(x => x, StringComparer.Ordinal)));
        }
        return new PrivacySnapshot(surface, excluded, twins, surface + ";" + string.Join(";", rev));
    }

    public sealed record FolderCount(string Name, bool Locked, int? Count);

    /// <summary>The folders of one kind with their counts. A locked folder (not unlocked) shows its name and its lock and no count; hidden and adult-blocked folders are not listed.
    /// Counts cover only what the person may see.</summary>
    public static List<FolderCount> FolderCounts(PrivacyInput input, Kind kind, IReadOnlyCollection<Copy> all)
    {
        var snap = Snapshot(input, Surface.Search, all);
        var locked = PrivacyInput.Of(input.Locked, kind); var unlocked = PrivacyInput.Of(input.UnlockedNow, kind);
        var hidden = PrivacyInput.Of(input.Hidden, kind);
        var result = new List<FolderCount>();
        foreach (var g in all.Where(c => c.Item.Kind == kind).GroupBy(c => c.Item.Group))
        {
            if (hidden.Contains(g.Key)) continue;
            var isLocked = locked.Contains(g.Key);
            if (isLocked && !unlocked.Contains(g.Key)) { if (!input.Kids) result.Add(new FolderCount(g.Key, true, null)); continue; }
            if (!snap.FolderOk(kind, g.Key)) continue;
            result.Add(new FolderCount(g.Key, isLocked, g.Count()));
        }
        return result;
    }

    /// <summary>Genres a person may filter by: only values that exist in what is visible (never one found only in a locked folder).</summary>
    public static List<string> Genres(PrivacySnapshot snap, Kind kind, IEnumerable<Copy> all, Func<Item, string?> genreOf)
        => snap.Filter(all.Where(c => c.Item.Kind == kind)).Select(c => genreOf(c.Item)).Where(g => !string.IsNullOrEmpty(g)).Select(g => g!).Distinct().OrderBy(g => g, StringComparer.Ordinal).ToList();

    public static List<int> Years(PrivacySnapshot snap, Kind kind, IEnumerable<Copy> all)
        => snap.Filter(all.Where(c => c.Item.Kind == kind)).Where(c => c.Item.Year is not null).Select(c => c.Item.Year!.Value).Distinct().OrderByDescending(y => y).ToList();

    public static List<Copy> Search(PrivacySnapshot snap, IEnumerable<Copy> all, string query)
    {
        var q = IdentityKey.Normalize(query);
        if (q.Length == 0) return new List<Copy>();
        return snap.Filter(all).Where(c => IdentityKey.Normalize(c.Item.Title).Contains(q, StringComparison.Ordinal)).ToList();
    }

    /// <summary>Titles like this one: the same kind, sharing words of the name, never the title itself and never anything restricted.</summary>
    public static List<Copy> Similar(PrivacySnapshot snap, Copy of, IEnumerable<Copy> all, int max = 12)
    {
        var mine = IdentityKey.Words(of.Item.Title).Where(w => w.Length > 2).ToHashSet();
        var myKey = IdentityKey.Make(of.Item.Title);
        return snap.Filter(all).Where(c => c.Item.Kind == of.Item.Kind && IdentityKey.Make(c.Item.Title) != myKey)
            .Select(c => (Copy: c, Shared: IdentityKey.Words(c.Item.Title).Count(w => mine.Contains(w))))
            .Where(t => t.Shared > 0).OrderByDescending(t => t.Shared).ThenBy(t => t.Copy.Key, StringComparer.Ordinal).Take(max).Select(t => t.Copy).ToList();
    }
}

/// <summary>Something built from the recommendation surface (a shelf, a count, a picture list) is kept under the revision of what was restricted at the time.
/// When a folder is locked, hidden or unlocked-then-relocked, the revision changes, so a value built in another state is never returned. Nothing identifying restricted content is stored.</summary>
public sealed class RestrictedCache<T>
{
    private readonly Dictionary<string, (string Revision, T Value)> _items = new();

    public T GetOrBuild(string name, string revision, Func<T> build)
    {
        if (_items.TryGetValue(name, out var e) && e.Revision == revision) return e.Value;
        var v = build();
        _items[name] = (revision, v);
        return v;
    }

    /// <summary>Drops every entry (a lock or hide change purges, not just filters).</summary>
    public void Purge() => _items.Clear();
    public int Count => _items.Count;
}
