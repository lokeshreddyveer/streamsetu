using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using StreamSetu.Core.SmartMix;
using Xunit;

namespace StreamSetu.Core.Tests;

/// <summary>Runs every shared Smart Mix fixture (smartmix/fixtures) against the C# engine: ids, hero art and every diagnostics field must match the reference exactly.</summary>
public class SmartMixFixtureTests
{
    private static string Dir()
    {
        var d = new DirectoryInfo(AppContext.BaseDirectory);
        while (d is not null)
        {
            var p = Path.Combine(d.FullName, "smartmix", "fixtures");
            if (Directory.Exists(p)) return p;
            d = d.Parent;
        }
        throw new DirectoryNotFoundException("smartmix/fixtures not found above " + AppContext.BaseDirectory);
    }

    public static IEnumerable<object[]> CaseNames() =>
        Directory.GetFiles(Dir(), "*.json").Select(f => Path.GetFileNameWithoutExtension(f)!).Where(n => n is not ("prng" or "features")).OrderBy(n => n, StringComparer.Ordinal).Select(n => new object[] { n });

    private static JsonElement Load(string name) => JsonDocument.Parse(File.ReadAllText(Path.Combine(Dir(), name + ".json"))).RootElement;

    private static string? Str(JsonElement e, string n) => e.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
    private static long? Num(JsonElement e, string n) => e.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt64() : null;
    private static bool Bool(JsonElement e, string n, bool d) => e.TryGetProperty(n, out var v) && v.ValueKind is JsonValueKind.True or JsonValueKind.False ? v.GetBoolean() : d;

    private static void Apply(Cand c, string field, JsonElement v)
    {
        string? s = v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        long? n = v.ValueKind == JsonValueKind.Number ? v.GetInt64() : null;
        bool b = v.ValueKind == JsonValueKind.True;
        switch (field)
        {
            case "id": c.Id = s!; break;
            case "kind": c.Kind = s!; break;
            case "key": c.Key = s ?? ""; break;
            case "year": c.Year = n; break;
            case "added": c.Added = n; break;
            case "rating": c.Rating = s; break;
            case "q": c.Q = n ?? 0; break;
            case "cam": c.Cam = b; break;
            case "lang": c.Lang = s; break;
            case "folder": c.Folder = s; break;
            case "franchise": c.Franchise = s; break;
            case "genre": c.Genre = s; break;
            case "poster": c.Poster = b; break;
            case "backdrop": c.Backdrop = b; break;
            case "watched": c.Watched = b; break;
            case "completed": c.Completed = b; break;
            case "lastWatched": c.LastWatched = n; break;
            case "p7": c.P7 = n ?? 0; break;
            case "p30": c.P30 = n ?? 0; break;
            case "restricted": c.Restricted = b; break;
            case "dismissed": c.Dismissed = b; break;
            case "src": c.Src = n ?? 0; break;
            case "trend": case "loadsAgo": break; // never taken from input
            default: throw new InvalidOperationException("unknown candidate field " + field);
        }
    }

    private static Cand ParseCand(JsonElement e)
    {
        var c = new Cand();
        foreach (var p in e.EnumerateObject()) Apply(c, p.Name, p.Value);
        return c;
    }

    private static List<Cand> Generate(string name, long seed, int n, int folders)
    {
        var g = new SplitMix64(Fnv.Hash64($"smartmix-gen1|{name}|{seed}"));
        long U(long k) => (long)g.Uniform((ulong)k);
        string[] langs = { "Telugu", "Hindi", "English", "Tamil", "Malayalam", "Kannada" };
        string[] genres = { "action", "drama", "comedy", "thriller", "family", "horror", "romance", "scifi" };
        var outList = new List<Cand>(n);
        for (var i = 0; i < n; i++)
        {
            var series = U(100) < 27;
            var c = new Cand { Id = (series ? "s" : "m") + i, Kind = series ? "series" : "movie" };
            c.Key = "t" + U(Math.Max(1, n * 4 / 5));
            c.Year = 2026 - Math.Min(U(36), U(36));
            c.Added = U(100) < 5 ? null : U(700);
            var r = U(20);
            if (r == 0) c.Rating = ""; else if (r == 1) c.Rating = "0"; else if (r == 2) c.Rating = "10"; else if (r == 3) c.Rating = "10.0";
            else { var t = 30 + U(60); c.Rating = $"{t / 10}.{t % 10}"; }
            r = U(100);
            if (r < 8) { c.Q = 0; c.Cam = true; } else if (r < 15) c.Q = 1; else if (r < 45) c.Q = 2; else if (r < 75) c.Q = 3; else if (r < 92) c.Q = 4; else c.Q = 5;
            var a = U(6); var b = U(6); var lang = langs[Math.Min(a, b)];
            c.Lang = U(100) < 3 ? null : lang;
            var fa = U(folders); var fb = U(folders); c.Folder = "f" + (fa * fb) / folders;
            c.Franchise = U(100) < 20 ? "fr" + U(n / 50 + 1) : null;
            var gi = U(8); c.Genre = U(100) < 5 ? null : genres[gi];
            c.Poster = U(100) >= 12;
            c.Backdrop = U(100) < 55;
            c.Watched = U(100) < 6;
            c.Completed = c.Watched && U(100) < 70;
            var lw = U(120); c.LastWatched = c.Watched ? lw : null;
            c.P7 = U(100) < 4 ? 1 + U(5) : 0;
            c.P30 = c.P7 + (U(100) < 8 ? U(8) : 0);
            c.Restricted = U(1000) < 8;
            c.Dismissed = U(1000) < 3;
            c.Src = U(2);
            outList.Add(c);
        }
        return outList;
    }

    private static Affinity ReadAffinity(JsonElement s)
    {
        if (!s.TryGetProperty("affinity", out var a)) return Affinity.None;
        IReadOnlyList<string> Strs(string n) => a.TryGetProperty(n, out var v) ? v.EnumerateArray().Select(x => x.GetString()!).ToList() : new List<string>();
        var dec = a.TryGetProperty("topDecades", out var d) ? d.EnumerateArray().Select(x => x.GetInt64()).ToList() : new List<long>();
        return new Affinity(Strs("topLangs"), Strs("topFolders"), Strs("topGenres"), dec);
    }

    private static TrendingInput ReadTmdb(JsonElement s)
    {
        if (!s.TryGetProperty("tmdb", out var t)) return new TrendingInput();
        TrendingCache? cache = null;
        if (t.TryGetProperty("cache", out var c) && c.ValueKind == JsonValueKind.Object)
            cache = new TrendingCache(c.GetProperty("fetchedDaysAgo").GetInt64(),
                c.GetProperty("entries").EnumerateArray().Select(e => new TrendingEntry(e.GetProperty("rank").GetInt64(), e.GetProperty("type").GetString()!, e.GetProperty("title").GetString()!, Str(e, "orig"), Num(e, "year"))).ToList());
        return new TrendingInput(Bool(t, "enabled", true), Bool(t, "keyPresent", false), cache);
    }

    private static string Digest(Dictionary<string, ShelfResult> res, IEnumerable<string> shelves)
    {
        var sb = new StringBuilder();
        foreach (var s in shelves) sb.Append(s).Append(':').Append(string.Join("\n", res[s].Items.Select(c => c.Id))).Append('\n');
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(sb.ToString()))).ToLowerInvariant();
    }

    private static void CheckDiag(string where, JsonElement exp, Diag d)
    {
        foreach (var p in exp.EnumerateObject())
        {
            object actual = p.Name switch
            {
                "inCount" => d.InCount, "groups" => d.Groups, "restricted" => d.Restricted, "dismissed" => d.Dismissed, "camOnly" => d.CamOnly, "noArtwork" => d.NoArtwork,
                "watched" => d.Watched, "lang" => d.Lang, "notTrending" => d.NotTrending, "pool" => d.Pool, "drawn" => d.Drawn, "tier" => d.Tier, "tiny" => d.Tiny,
                "hidden" => d.Hidden, "fallback" => d.Fallback, "diversityRelaxed" => d.DiversityRelaxed, "caption" => d.Caption, "tmdb" => d.Tmdb, "trendMode" => d.TrendMode,
                _ => throw new InvalidOperationException("unknown diag field " + p.Name),
            };
            object expected = p.Value.ValueKind switch
            {
                JsonValueKind.Number => p.Value.GetInt64(), JsonValueKind.True => true, JsonValueKind.False => false, _ => p.Value.GetString()!,
            };
            Assert.True(Equals(expected, actual), $"{where}: diag.{p.Name} expected {expected} but was {actual}");
        }
    }

    [Theory]
    [MemberData(nameof(CaseNames))]
    public void MatchesTheReferenceExactly(string name)
    {
        var doc = Load(name);
        List<Cand> library = doc.TryGetProperty("generator", out var g)
            ? Generate(g.GetProperty("name").GetString()!, g.GetProperty("seed").GetInt64(), g.GetProperty("n").GetInt32(), g.GetProperty("folders").GetInt32())
            : doc.GetProperty("library").EnumerateArray().Select(ParseCand).ToList();
        var state = new SmartMixState();
        var stepNo = 0;
        foreach (var step in doc.GetProperty("steps").EnumerateArray())
        {
            stepNo++;
            var lib = library.Select(c => c.Clone()).ToList();
            if (step.TryGetProperty("patch", out var patch))
                foreach (var pp in patch.EnumerateObject())
                    foreach (var c in lib.Where(c => c.Id == pp.Name))
                        foreach (var f in pp.Value.EnumerateObject()) Apply(c, f.Name, f.Value);
            var ctx = new SmartMixContext(step.GetProperty("profile").GetString()!, step.GetProperty("dayKey").GetString()!, Num(step, "refreshCounter") ?? 0, Str(step, "preferredLang"),
                ReadAffinity(step), Num(step, "poolCap"), ReadTmdb(step));
            var shelves = step.GetProperty("shelves").EnumerateArray().Select(x => x.GetString()!).ToList();
            var res = SmartMixEngine.Run(lib, ctx, shelves, state, Bool(step, "commit", false));
            var expect = step.GetProperty("expect");
            if (expect.TryGetProperty("digest", out var dg))
            {
                Assert.Equal(dg.GetString(), Digest(res, shelves));
                foreach (var cnt in expect.GetProperty("counts").EnumerateObject()) Assert.Equal(cnt.Value.GetInt32(), res[cnt.Name].Items.Count);
                foreach (var first in expect.GetProperty("first").EnumerateObject())
                    Assert.Equal(first.Value.EnumerateArray().Select(x => x.GetString()!).ToList(), res[first.Name].Items.Take(14).Select(c => c.Id).ToList());
            }
            else
                foreach (var shelf in expect.EnumerateObject())
                {
                    var where = $"{name} step {stepNo} shelf {shelf.Name}";
                    Assert.Equal(shelf.Value.GetProperty("ids").EnumerateArray().Select(x => x.GetString()!).ToList(), res[shelf.Name].Items.Select(c => c.Id).ToList());
                    Assert.Equal(shelf.Value.GetProperty("art").EnumerateArray().Select(x => x.GetString()!).ToList(), res[shelf.Name].Art.ToList());
                    CheckDiag(where, shelf.Value.GetProperty("diag"), res[shelf.Name].Diag);
                }
        }
    }

    [Fact]
    public void PrngVectorsMatch()
    {
        var doc = Load("prng");
        foreach (var f in doc.GetProperty("fnv1a64").EnumerateArray())
            Assert.Equal(f.GetProperty("hex").GetString(), Fnv.Hash64(f.GetProperty("input").GetString()!).ToString("X16"));
        foreach (var s in doc.GetProperty("splitmix64").EnumerateArray())
        {
            var g = new SplitMix64(s.GetProperty("seed").GetUInt64());
            foreach (var h in s.GetProperty("hex").EnumerateArray()) Assert.Equal(h.GetString(), g.Next().ToString("X16"));
        }
        foreach (var u in doc.GetProperty("uniform").EnumerateArray())
        {
            var vals = u.GetProperty("values").EnumerateArray().Select(x => x.GetUInt64()).ToList();
            var g = u.TryGetProperty("seedString", out var ss) ? new SplitMix64(Fnv.Hash64(ss.GetString()!)) : new SplitMix64(u.GetProperty("splitmixSeed").GetUInt64());
            if (u.TryGetProperty("n", out var n)) foreach (var v in vals) Assert.Equal(v, g.Uniform(n.GetUInt64()));
            else { var ns = u.GetProperty("ns").EnumerateArray().Select(x => x.GetUInt64()).ToList(); for (var i = 0; i < ns.Count; i++) Assert.Equal(vals[i], g.Uniform(ns[i])); }
        }
        var seed = doc.GetProperty("seedString");
        Assert.Equal(seed.GetProperty("value").GetString(), $"smartmix1|{seed.GetProperty("profile").GetString()}|{seed.GetProperty("shelf").GetString()}|{seed.GetProperty("day").GetString()}|{seed.GetProperty("counter").GetInt32()}");
    }

    [Fact]
    public void FeatureTablesMatch()
    {
        var f = Load("features");
        long? N(JsonElement e) => e.ValueKind == JsonValueKind.Null ? null : e.GetInt64();
        foreach (var r in f.GetProperty("release").EnumerateArray()) Assert.Equal(r[2].GetInt64(), SmartMixEngine.FRelease(N(r[0]), r[1].GetInt64()));
        foreach (var r in f.GetProperty("added").EnumerateArray()) Assert.Equal(r[1].GetInt64(), SmartMixEngine.FAdded(N(r[0])));
        foreach (var r in f.GetProperty("quality").EnumerateArray()) Assert.Equal(r[1].GetInt64(), SmartMixEngine.FQuality(r[0].GetInt64()));
        foreach (var r in f.GetProperty("language").EnumerateArray()) Assert.Equal(r[2].GetInt64(), SmartMixEngine.FLanguage(r[0].GetString(), r[1].GetString()));
        foreach (var r in f.GetProperty("rating").EnumerateArray()) Assert.Equal(r[1].GetInt64(), SmartMixEngine.FRating(r[0].GetString()));
        foreach (var r in f.GetProperty("popularity").EnumerateArray()) Assert.Equal(r[2].GetInt64(), SmartMixEngine.FPopularity(r[0].GetInt64(), r[1].GetInt64()));
        foreach (var r in f.GetProperty("fresh").EnumerateArray()) Assert.Equal(r[1].GetInt64(), SmartMixEngine.FFresh(N(r[0])));
        var ac = f.GetProperty("affinityContext");
        var aff = new Affinity(ac.GetProperty("topLangs").EnumerateArray().Select(x => x.GetString()!).ToList(), ac.GetProperty("topFolders").EnumerateArray().Select(x => x.GetString()!).ToList(),
            ac.GetProperty("topGenres").EnumerateArray().Select(x => x.GetString()!).ToList(), ac.GetProperty("topDecades").EnumerateArray().Select(x => x.GetInt64()).ToList());
        foreach (var r in f.GetProperty("affinity").EnumerateArray())
        {
            var c = r[0];
            Assert.Equal(r[1].GetInt64(), SmartMixEngine.FAffinity(Str(c, "lang"), Str(c, "folder"), Str(c, "genre"), Num(c, "year"), aff));
        }
    }
}
