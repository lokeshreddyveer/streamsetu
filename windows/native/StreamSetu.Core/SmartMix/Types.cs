namespace StreamSetu.Core.SmartMix;

/// <summary>One copy of a title as the engine sees it. Identity grouping, restriction and ranking read only these fields.</summary>
public sealed class Cand
{
    public string Id { get; set; } = "";
    public string Kind { get; set; } = "movie";
    /// <summary>The identity key, already normalised.</summary>
    public string Key { get; set; } = "";
    public long? Year { get; set; }
    /// <summary>Days before the day start; null when unknown.</summary>
    public long? Added { get; set; }
    public string? Rating { get; set; }
    public long Q { get; set; } = 2;
    public bool Cam { get; set; }
    public string? Lang { get; set; }
    public string? Folder { get; set; }
    public string? Franchise { get; set; }
    public string? Genre { get; set; }
    public bool Poster { get; set; } = true;
    public bool Backdrop { get; set; }
    public bool Watched { get; set; }
    public bool Completed { get; set; }
    public long? LastWatched { get; set; }
    public long P7 { get; set; }
    public long P30 { get; set; }
    public long? Trend { get; set; }
    public long? LoadsAgo { get; set; }
    public bool Restricted { get; set; }
    public bool Dismissed { get; set; }
    public long Src { get; set; }
    public bool CamOnly { get; set; }

    public Cand Clone() => (Cand)MemberwiseClone();
}

public sealed record Affinity(IReadOnlyList<string> TopLangs, IReadOnlyList<string> TopFolders, IReadOnlyList<string> TopGenres, IReadOnlyList<long> TopDecades)
{
    public static readonly Affinity None = new(Array.Empty<string>(), Array.Empty<string>(), Array.Empty<string>(), Array.Empty<long>());
}

public sealed record TrendingEntry(long Rank, string Type, string Title, string? Orig, long? Year);
public sealed record TrendingCache(long FetchedDaysAgo, IReadOnlyList<TrendingEntry> Entries);
/// <summary>The weekly list is used only with the person's own TMDB key; the app ships none.</summary>
public sealed record TrendingInput(bool Enabled = true, bool KeyPresent = false, TrendingCache? Cache = null);

public sealed record SmartMixContext(string Profile, string DayKey, long RefreshCounter = 0, string? PreferredLang = null, Affinity? Affinity = null, long? PoolCap = null, TrendingInput? Tmdb = null);

public sealed class Diag
{
    public long InCount, Groups, Restricted, Dismissed, CamOnly, NoArtwork, Watched, Lang, NotTrending, Pool, Drawn, Tier;
    public bool Tiny, Hidden, DiversityRelaxed, TrendMode;
    public string Fallback = "none", Caption = "", Tmdb = "";
}

public sealed record ShelfResult(IReadOnlyList<Cand> Items, Diag Diag, IReadOnlyList<string> Art)
{
    public IEnumerable<string> Ids => Items.Select(c => c.Id);
}

/// <summary>Shown-history for repeat suppression, per profile and shelf. Never holds a restricted item.</summary>
public sealed class SmartMixState
{
    public sealed record Row(string IdentityKey, long? Year, string ItemId, long Seq);
    public sealed class Shelf { public long Refresh; public string LoadKey = ""; public long Seq; public List<Row> Rows = new(); }

    private readonly Dictionary<(string, string), Shelf> _s = new();
    public Shelf Get(string profile, string shelf)
    {
        if (!_s.TryGetValue((profile, shelf), out var st)) _s[(profile, shelf)] = st = new Shelf();
        return st;
    }

    public Dictionary<string, long> LoadsAgo(string profile, string shelf, string loadKey)
    {
        var st = Get(profile, shelf);
        var eff = st.LoadKey == loadKey ? st.Seq : st.Seq + 1;
        var m = new Dictionary<string, long>();
        foreach (var r in st.Rows)
        {
            var a = eff - r.Seq;
            if (a >= 1) m[r.IdentityKey] = m.TryGetValue(r.IdentityKey, out var o) ? Math.Min(o, a) : a;
        }
        return m;
    }

    public void Record(string profile, string shelf, string loadKey, IEnumerable<(string Key, long? Year, string Id)> rows)
    {
        var st = Get(profile, shelf);
        if (st.LoadKey == loadKey) return;
        st.LoadKey = loadKey; st.Seq += 1;
        var all = st.Rows.Concat(rows.Select(r => new Row(r.Key, r.Year, r.Id, st.Seq))).OrderByDescending(r => r.Seq).Take(48).ToList();
        st.Rows = all;
    }

    /// <summary>Forgets everything for one profile (a restriction change or a profile removal).</summary>
    public void Purge(string profile) { foreach (var k in _s.Keys.Where(k => k.Item1 == profile).ToList()) _s.Remove(k); }
}
