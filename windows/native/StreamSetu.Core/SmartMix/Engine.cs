using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace StreamSetu.Core.SmartMix;

/// <summary>The Smart Mix ranking: integer arithmetic only, the same picks as the Swift and Kotlin engines for the same inputs (contract: the shared fixtures).</summary>
public static class SmartMixEngine
{
    public const long TmdbDisplayDays = 30, TmdbMaxDays = 180, TmdbMinMatches = 6;

    private sealed record ShelfDef(int[] W, bool Sharp, int Pool, int Size, int MinCount, bool Mixes);

    private static readonly Dictionary<string, ShelfDef> Shelves = new()
    {
        ["hero"] = new([10, 10, 15, 15, 5, 10, 20, 15], true, 2000, 12, 3, true),
        ["for-you"] = new([5, 5, 10, 15, 5, 10, 40, 10], true, 2000, 14, 6, false),
        ["rediscover"] = new([10, 0, 15, 15, 10, 0, 35, 15], true, 2000, 14, 6, false),
        ["lang-pref"] = new([15, 15, 25, 0, 5, 15, 15, 10], true, 2000, 14, 6, false),
        ["top-week"] = new([10, 15, 10, 10, 5, 40, 0, 10], true, 2000, 14, 6, false),
        ["trending-library"] = new([10, 15, 10, 10, 5, 40, 0, 10], true, 2000, 14, 3, false),
        ["folder"] = new([10, 25, 30, 20, 0, 0, 0, 15], false, 200, 12, 1, false),
    };

    public static bool IsFolderShelf(string id) => id.StartsWith("folder:", StringComparison.Ordinal);
    private static ShelfDef DefOf(string id) => Shelves[IsFolderShelf(id) ? "folder" : id];

    // ---------------- features (0..1000)
    public static long FRelease(long? year, long nowYear)
    {
        if (year is null) return 300;
        var age = Math.Max(0, nowYear - year.Value);
        return age switch { 0 => 1000, 1 => 850, 2 => 700, 3 => 560, 4 => 450, 5 => 360, <= 8 => 260, <= 15 => 150, _ => 80 };
    }

    public static long FAdded(long? days)
    {
        if (days is null) return 300;
        var d = Math.Max(0, days.Value);
        if (d <= 7) return 1000; if (d <= 30) return 800; if (d <= 90) return 600; if (d <= 180) return 450; if (d <= 365) return 300;
        return 150;
    }

    public static long FQuality(long r) => r switch { 5 => 1000, 4 => 800, 3 => 600, 2 => 450, 1 => 250, _ => 0 };

    public static long FLanguage(string? lang, string? pref) => pref is null || lang is null ? 500 : lang == pref ? 1000 : 150;

    private static readonly Regex RatingRe = new(@"^[0-9]{1,2}(\.[0-9]{1,2})?\z", RegexOptions.CultureInvariant);

    public static long FRating(string? text)
    {
        if (text is null || !RatingRe.IsMatch(text)) return 500;
        var dot = text.IndexOf('.');
        var whole = long.Parse(dot < 0 ? text : text[..dot], CultureInfo.InvariantCulture);
        var tenths = whole * 10 + (dot >= 0 ? text[dot + 1] - '0' : 0);
        if (tenths < 1 || tenths > 99) return 500;
        var raw = Math.Min(1000, Math.Max(0, 500 + (tenths - 60) * 12));
        return 500 + (raw - 500) * 40 / 100;
    }

    public static long FPopularity(long p7, long p30)
    {
        var c = p7 * 2 + p30;
        if (c <= 0) return 0; if (c == 1) return 400; if (c == 2) return 600; if (c <= 4) return 750; if (c <= 9) return 900;
        return 1000;
    }

    public static long FAffinity(string? lang, string? folder, string? genre, long? year, Affinity aff)
    {
        long s = 0;
        if (lang is not null)
        {
            if (aff.TopLangs.Count > 0 && lang == aff.TopLangs[0]) s += 400;
            else if (aff.TopLangs.Skip(1).Take(2).Contains(lang)) s += 250;
        }
        if (folder is not null && aff.TopFolders.Take(5).Contains(folder)) s += 200;
        if (genre is not null && aff.TopGenres.Take(5).Contains(genre)) s += 100;
        if (year is not null && aff.TopDecades.Take(2).Contains(year.Value / 10 * 10)) s += 150;
        return Math.Min(1000, s);
    }

    public static long FFresh(long? ago) => ago switch { null => 1000, 1 => 100, 2 => 400, 3 => 700, _ => 1000 };

    // ---------------- prepare: identity grouping and the representative of each cluster
    private static List<List<Cand>> GroupClusters(List<Cand> members)
    {
        members.Sort((a, b) =>
        {
            if ((a.Year is null) != (b.Year is null)) return a.Year is null ? 1 : -1;
            if (a.Year != b.Year) return a.Year!.Value.CompareTo(b.Year!.Value);
            return Utf8Order.Compare(a.Id, b.Id);
        });
        var clusters = new List<(long First, List<Cand> Members)>();
        var nil = new List<Cand>();
        foreach (var m in members)
        {
            if (m.Year is null) { nil.Add(m); continue; }
            if (clusters.Count > 0 && m.Year.Value - clusters[^1].First <= 1) clusters[^1].Members.Add(m);
            else clusters.Add((m.Year.Value, new List<Cand> { m }));
        }
        var outList = clusters.Select(c => c.Members).ToList();
        if (nil.Count > 0) { if (outList.Count > 0) outList[0].AddRange(nil); else outList.Add(nil); }
        return outList;
    }

    private static Cand PickRep(List<Cand> members, string? prefLang)
    {
        var pool = members.Where(m => !m.Cam).ToList();
        if (pool.Count == 0) pool = members;
        Cand best = pool[0];
        foreach (var m in pool.Skip(1)) if (RepCompare(m, best, prefLang) < 0) best = m;
        return best;
    }

    private static int RepCompare(Cand a, Cand b, string? pref)
    {
        int la = pref is not null && a.Lang == pref ? 0 : 1, lb = pref is not null && b.Lang == pref ? 0 : 1;
        if (la != lb) return la.CompareTo(lb);
        if (a.Q != b.Q) return b.Q.CompareTo(a.Q);
        if (a.Src != b.Src) return a.Src.CompareTo(b.Src);
        if ((a.Added is null) != (b.Added is null)) return a.Added is null ? 1 : -1;
        if (a.Added != b.Added) return a.Added!.Value.CompareTo(b.Added!.Value);
        return Utf8Order.Compare(a.Id, b.Id);
    }

    private sealed class Prepared
    {
        public long InCount;
        public List<Cand> Groups = new();
        public Dictionary<string, List<Cand>>? ByFolder;
    }

    private static Prepared Prepare(List<Cand> cands, string? prefLang)
    {
        var groups = new Dictionary<(string, string), List<Cand>>();
        foreach (var c in cands)
        {
            if (!groups.TryGetValue((c.Kind, c.Key), out var l)) groups[(c.Kind, c.Key)] = l = new();
            l.Add(c);
        }
        var keys = groups.Keys.ToList();
        keys.Sort((a, b) => { var k = Utf8Order.Compare(a.Item1, b.Item1); return k != 0 ? k : Utf8Order.Compare(a.Item2, b.Item2); });
        var reps = new List<Cand>();
        foreach (var key in keys)
            foreach (var cl in GroupClusters(groups[key]))
            {
                var rep = PickRep(cl, prefLang).Clone();
                rep.Restricted = cl.Any(m => m.Restricted);
                rep.Dismissed = cl.Any(m => m.Dismissed);
                rep.CamOnly = cl.All(m => m.Cam);
                rep.Watched = cl.Any(m => m.Watched);
                rep.Completed = cl.Any(m => m.Completed);
                rep.LastWatched = cl.Where(m => m.LastWatched is not null).Select(m => m.LastWatched).DefaultIfEmpty(null).Min();
                rep.P7 = cl.Sum(m => m.P7); rep.P30 = cl.Sum(m => m.P30);
                rep.Trend = cl.Where(m => m.Trend is not null).Select(m => m.Trend).DefaultIfEmpty(null).Min();
                rep.LoadsAgo = cl.Where(m => m.LoadsAgo is not null).Select(m => m.LoadsAgo).DefaultIfEmpty(null).Min();
                reps.Add(rep);
            }
        return new Prepared { InCount = cands.Count, Groups = reps };
    }

    // ---------------- scoring and draw
    private static long Score(Cand c, string shelfId, ShelfDef sd, SmartMixContext ctx, int relax, long nowYear)
    {
        long[] feats =
        {
            FRelease(c.Year, nowYear), FAdded(c.Added), FQuality(c.Q), FLanguage(c.Lang, ctx.PreferredLang), FRating(c.Rating), FPopularity(c.P7, c.P30),
            FAffinity(c.Lang, c.Folder, c.Genre, c.Year, ctx.Affinity ?? Affinity.None), relax >= 1 ? 1000 : FFresh(c.LoadsAgo),
        };
        long sum = 0;
        for (var i = 0; i < 8; i++) sum += sd.W[i] * feats[i];
        var s = sum / 100;
        if (shelfId == "hero") { if (c.Backdrop) s += 50; if (c.Trend is not null) s += 60; }
        else if (shelfId is "top-week" or "trending-library") { if (c.Trend is not null) s += 100; }
        if (relax >= 3 && c.Watched && shelfId != "rediscover") s -= 200;
        return Math.Max(0, Math.Min(1100, s));
    }

    private static long Weight(long s, bool sharp) => sharp ? 1 + s * s / 100 : 1 + s;

    private static (List<int> Picks, bool Relaxed) Draw(List<Cand> items, long[] ws, int k, SplitMix64 rng, ShelfDef sd, int relax, string shelfId, List<int> forced)
    {
        var n = items.Count; var w = (long[])ws.Clone(); var picks = new List<int>();
        var div = relax < 2; var langRule = shelfId != "lang-pref"; var relaxed = false;
        foreach (var i in forced) { w[i] = 0; picks.Add(i); }
        bool Blocked(int i)
        {
            if (!div || picks.Count < 2) return false;
            var a = items[picks[^1]]; var b = items[picks[^2]]; var c = items[i];
            if (c.Franchise is not null && a.Franchise == c.Franchise && b.Franchise == c.Franchise) return true;
            if (c.Genre is not null && a.Genre == c.Genre && b.Genre == c.Genre) return true;
            if (sd.Mixes && a.Kind == c.Kind && b.Kind == c.Kind) return true;
            if (langRule && c.Lang is not null && a.Lang == c.Lang && b.Lang == c.Lang) return true;
            return false;
        }
        var elig = new List<int>();
        while (picks.Count < k)
        {
            elig.Clear();
            for (var i = 0; i < n; i++) if (w[i] > 0 && !Blocked(i)) elig.Add(i);
            if (elig.Count == 0)
            {
                for (var i = 0; i < n; i++) if (w[i] > 0) elig.Add(i);
                if (elig.Count > 0) relaxed = true;
            }
            long total = 0; foreach (var i in elig) total += w[i];
            if (total == 0) break;
            var r = rng.Uniform((ulong)total); ulong acc = 0; var p = elig[^1];
            foreach (var i in elig) { acc += (ulong)w[i]; if (r < acc) { p = i; break; } }
            w[p] = 0; picks.Add(p);
            if (div)
            {
                var pc = items[p];
                for (var j = 0; j < n; j++)
                {
                    if (w[j] == 0) continue;
                    var cj = items[j];
                    if (pc.Franchise is not null && cj.Franchise == pc.Franchise) w[j] /= 4;
                    if (langRule && pc.Lang is not null && cj.Lang == pc.Lang && cj.Kind == pc.Kind) w[j] = w[j] * 3 / 4;
                }
            }
        }
        return (picks, relaxed);
    }

    // ---------------- one shelf
    private static ShelfResult BuildShelf(Prepared prep, string shelfId, SmartMixContext ctx, bool trendingOrdered, long nowYear)
    {
        var sd = DefOf(shelfId); var isFolder = IsFolderShelf(shelfId);
        var folderKey = isFolder ? shelfId[7..] : null;
        var groups = prep.Groups;
        var diag = new Diag { InCount = prep.InCount, Groups = groups.Count };
        if (isFolder)
        {
            prep.ByFolder ??= prep.Groups.Where(c => c.Folder is not null).GroupBy(c => c.Folder!).ToDictionary(g => g.Key, g => g.ToList());
            groups = prep.ByFolder.GetValueOrDefault(folderKey!) ?? new List<Cand>();
            diag.Groups = groups.Count;
        }
        var baseList = new List<Cand>();
        foreach (var c in groups) { if (c.Restricted) { diag.Restricted++; continue; } baseList.Add(c); }
        if (!isFolder)
        {
            var keep = new List<Cand>();
            foreach (var c in baseList) { if (c.Dismissed) diag.Dismissed++; else keep.Add(c); }
            baseList = keep;
        }
        if (shelfId == "lang-pref" && string.IsNullOrEmpty(ctx.PreferredLang)) { diag.Hidden = true; return new ShelfResult(new List<Cand>(), diag, new List<string>()); }

        var need = Math.Min(sd.MinCount, baseList.Count);
        var trendMode = shelfId == "trending-library" && baseList.Count(c => c.Trend is not null) >= 3;
        diag.TrendMode = trendMode;
        int tierUsed = 0; long cCam = 0, cArt = 0, cWatched = 0, cLang = 0, cNotTrend = 0; bool tiny = false, relaxedDiv = false;
        List<Cand> items = new(); List<int> picks = new();
        for (var tier = 0; tier <= 5; tier++)
        {
            var elig = new List<Cand>(); cCam = cArt = cWatched = cLang = cNotTrend = 0;
            foreach (var c in baseList)
            {
                if (c.CamOnly && tier < 5) { cCam++; continue; }
                if (shelfId == "hero") { if (!(c.Backdrop || c.Poster)) { cArt++; continue; } }
                else if (!c.Poster && tier < 4) { cArt++; continue; }
                if (shelfId == "lang-pref" && c.Lang != ctx.PreferredLang) { cLang++; continue; }
                if (trendMode && c.Trend is null) { cNotTrend++; continue; }
                if (!isFolder)
                {
                    if (shelfId == "rediscover")
                    {
                        if (c.Watched && (!c.Completed || (c.LastWatched is not null && c.LastWatched <= 30))) { cWatched++; continue; }
                    }
                    else if (c.Watched && tier < 3) { cWatched++; continue; }
                }
                elig.Add(c);
            }
            tiny = elig.Count <= sd.Size;
            var eff = tiny ? Math.Max(tier, 1) : tier;
            var scored = elig.Select(c => (S: Score(c, shelfId, sd, ctx, eff, nowYear), C: c)).ToList();
            scored.Sort((a, b) => a.S != b.S ? b.S.CompareTo(a.S) : Utf8Order.Compare(a.C.Id, b.C.Id));
            var cap = isFolder ? Math.Min(sd.Pool, ctx.PoolCap ?? sd.Pool) : (ctx.PoolCap ?? sd.Pool);
            if (cap < scored.Count) scored = scored.GetRange(0, (int)Math.Max(0, cap));
            items = scored.Select(t => t.C).ToList();
            var ws = scored.Select(t => Weight(t.S, sd.Sharp)).ToArray();
            var forced = new List<int>();
            if (trendingOrdered && shelfId == "top-week")
            {
                var order = Enumerable.Range(0, items.Count).Where(i => items[i].Trend is not null).ToList();
                order.Sort((a, b) => items[a].Trend != items[b].Trend ? items[a].Trend!.Value.CompareTo(items[b].Trend!.Value) : Utf8Order.Compare(items[a].Id, items[b].Id));
                forced = order.Take(sd.Size).ToList();
            }
            var k = Math.Min(sd.Size, items.Count);
            var rng = new SplitMix64(Fnv.Hash64($"smartmix1|{ctx.Profile}|{shelfId}|{ctx.DayKey}|{ctx.RefreshCounter.ToString(CultureInfo.InvariantCulture)}"));
            (picks, relaxedDiv) = k > 0 ? Draw(items, ws, k, rng, sd, eff, shelfId, forced) : (new List<int>(), false);
            tierUsed = tier;
            if (picks.Count >= need) break;
        }
        diag.CamOnly = cCam; diag.NoArtwork = cArt; diag.Watched = cWatched; diag.Lang = cLang; diag.NotTrending = cNotTrend;
        diag.Tier = tierUsed; diag.Tiny = tiny; diag.Pool = items.Count; diag.Drawn = picks.Count; diag.DiversityRelaxed = relaxedDiv;
        var outList = picks.Select(i => items[i]).ToList();
        if (outList.Count == 0 && shelfId != "lang-pref")
        {
            var rec = baseList.Where(c => c.Poster || c.Backdrop).ToList();
            rec.Sort(RecentOrder);
            diag.Fallback = "recentlyAdded";
            if (rec.Count == 0 && shelfId != "hero")
            {
                rec = baseList.ToList(); rec.Sort((a, b) => Utf8Order.Compare(a.Id, b.Id)); diag.Fallback = "plainLibrary";
            }
            outList = rec.Take(sd.Size).ToList();
            if (outList.Count == 0) diag.Fallback = shelfId == "hero" ? "existingFeatured" : "none";
        }
        else if (outList.Count == 0) diag.Hidden = true;
        var art = shelfId == "hero" ? outList.Select(c => c.Backdrop ? "backdrop" : "poster").ToList() : new List<string>();
        return new ShelfResult(outList, diag, art);
    }

    private static int RecentOrder(Cand a, Cand b)
    {
        if ((a.Added is null) != (b.Added is null)) return a.Added is null ? 1 : -1;
        if (a.Added != b.Added) return a.Added!.Value.CompareTo(b.Added!.Value);
        return Utf8Order.Compare(a.Id, b.Id);
    }

    // ---------------- trending
    /// <summary>NFKD, marks dropped, lower case, runs of anything but ASCII letters/digits and non-ASCII characters become one space, one leading article dropped.</summary>
    public static string FoldTitle(string s)
    {
        var d = s.Normalize(NormalizationForm.FormKD);
        var sb = new StringBuilder();
        foreach (var ch in d)
        {
            var cat = CharUnicodeInfo.GetUnicodeCategory(ch);
            if (cat is UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark) continue;
            var l = ch < 128 ? (ch >= 'A' && ch <= 'Z' ? (char)(ch + 32) : ch) : char.ToLowerInvariant(ch);
            if ((l >= '0' && l <= '9') || (l >= 'a' && l <= 'z') || l >= 0x80) sb.Append(l); else sb.Append(' ');
        }
        var words = sb.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
        if (words.Count > 1 && words[0] is "the" or "a" or "an") words.RemoveAt(0);
        return string.Join(' ', words);
    }

    public static Dictionary<string, long> MatchTrending(IReadOnlyList<TrendingEntry> entries, IReadOnlyList<Cand> cands)
    {
        var idx = new Dictionary<(string, string), List<Cand>>();
        foreach (var c in cands) { if (!idx.TryGetValue((c.Kind, c.Key), out var l)) idx[(c.Kind, c.Key)] = l = new(); l.Add(c); }
        var res = new Dictionary<string, long>();
        foreach (var e in entries.OrderBy(e => e.Rank))
        {
            var kind = e.Type == "movie" ? "movie" : "series";
            var names = new HashSet<string> { FoldTitle(e.Title) };
            if (!string.IsNullOrEmpty(e.Orig)) names.Add(FoldTitle(e.Orig));
            foreach (var nm in names)
                if (idx.TryGetValue((kind, nm), out var list))
                    foreach (var c in list)
                    {
                        if (e.Year is not null && c.Year is not null && Math.Abs(e.Year.Value - c.Year.Value) > 1) continue;
                        res.TryAdd(c.Id, e.Rank);
                    }
        }
        return res;
    }

    /// <summary>"off", "noCache", "purged" (cache older than 180 days: delete it), "expired" (31..180 days: local only) or "active".</summary>
    public static string TrendingStatus(TrendingInput? t)
    {
        t ??= new TrendingInput();
        if (!(t.Enabled && t.KeyPresent)) return "off";
        if (t.Cache is null) return "noCache";
        if (t.Cache.FetchedDaysAgo > TmdbMaxDays) return "purged";
        if (t.Cache.FetchedDaysAgo > TmdbDisplayDays) return "expired";
        return "active";
    }

    // ---------------- one load
    /// <summary>Builds the shelves in order. With <paramref name="commit"/> the shown items are recorded (the first successful render of a new load key).</summary>
    public static Dictionary<string, ShelfResult> Run(IReadOnlyList<Cand> library, SmartMixContext ctx, IReadOnlyList<string> shelves, SmartMixState state, bool commit)
    {
        var nowYear = long.Parse(ctx.DayKey[..4], CultureInfo.InvariantCulture);
        var loadKey = ctx.DayKey + "|" + ctx.RefreshCounter.ToString(CultureInfo.InvariantCulture);
        var status = TrendingStatus(ctx.Tmdb);
        var entries = status == "active" ? ctx.Tmdb!.Cache!.Entries : null;
        var result = new Dictionary<string, ShelfResult>();
        Prepared? plain = null;
        foreach (var shelfId in shelves)
        {
            var lk = state.LoadsAgo(ctx.Profile, shelfId, loadKey);
            Prepared prep;
            if (entries is null && lk.Count == 0 && plain is not null) prep = plain;
            else
            {
                var cs = new List<Cand>(library.Count);
                foreach (var c in library) { var d = c.Clone(); d.LoadsAgo = lk.TryGetValue(c.Key, out var a) ? a : null; d.Trend = null; cs.Add(d); }
                if (entries is not null)
                {
                    var matched = MatchTrending(entries, cs);
                    foreach (var d in cs) d.Trend = matched.TryGetValue(d.Id, out var r) ? r : null;
                }
                prep = Prepare(cs, ctx.PreferredLang);
                if (entries is null && lk.Count == 0) plain = prep;
            }
            var ordered = false;
            if (shelfId == "top-week" && entries is not null) ordered = prep.Groups.Count(g => !g.Restricted && g.Trend is not null) >= TmdbMinMatches;
            var r2 = BuildShelf(prep, shelfId, ctx, ordered, nowYear);
            r2.Diag.Caption = shelfId == "top-week" ? (ordered ? "trendingTMDB" : "mostWatchedHere")
                : shelfId == "trending-library" ? (r2.Diag.TrendMode ? "trendingTMDB" : "mostWatchedHere") : "";
            r2.Diag.Tmdb = shelfId is "top-week" or "trending-library" or "hero" ? status : "";
            result[shelfId] = r2;
            if (commit) state.Record(ctx.Profile, shelfId, loadKey, r2.Items.Where(c => !c.Restricted).Select(c => (c.Key, c.Year, c.Id)));
        }
        return result;
    }
}
