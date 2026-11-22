using System.Globalization;
using System.Text.Json;
using StreamSetu.Core.SmartMix;

namespace StreamSetu.Core;

/// <summary>TMDB weekly trending for Top This Week and Trending. Privacy: the only request is the public weekly list; nothing about the person is sent. On by default, active only with the person's own TMDB key.
/// No key is bundled with the app. Nothing is kept longer than 180 days.</summary>
public static class Tmdb
{
    public const string Attribution = "This product uses the TMDB API but is not endorsed or certified by TMDB.";
    public const int MaxCacheDays = 180, DisplayDays = 30, RefetchAfterHours = 24;

    public sealed record Cache(long FetchedAtMs, List<TrendingEntry> Entries);

    public static TrendingCache? ForEngine(Cache? c, DateTimeOffset now)
        => c is null ? null : new TrendingCache(Math.Max(0, (now.ToUnixTimeMilliseconds() - c.FetchedAtMs) / 86_400_000), c.Entries);

    public static bool NeedsRefetch(Cache? c, DateTimeOffset now) => c is null || now.ToUnixTimeMilliseconds() - c.FetchedAtMs >= RefetchAfterHours * 3_600_000L;

    /// <summary>The weekly lists of movies and shows, interleaved (movie 1, show 1, movie 2, ...) and renumbered, so one rank orders both.</summary>
    public static List<TrendingEntry> Interleave(IReadOnlyList<TrendingEntry> movies, IReadOnlyList<TrendingEntry> tv)
    {
        var all = new List<TrendingEntry>();
        for (var i = 0; i < Math.Max(movies.Count, tv.Count); i++)
        {
            if (i < movies.Count) all.Add(movies[i]);
            if (i < tv.Count) all.Add(tv[i]);
        }
        return all.Select((e, i) => e with { Rank = i + 1 }).ToList();
    }

    public static List<TrendingEntry> Parse(string json, string type)
    {
        var list = new List<TrendingEntry>();
        using var doc = JsonDocument.Parse(json);
        if (!doc.RootElement.TryGetProperty("results", out var results) || results.ValueKind != JsonValueKind.Array) return list;
        var rank = 0;
        foreach (var r in results.EnumerateArray())
        {
            rank++;
            string? Get(string n) => r.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
            var title = Get("title") ?? Get("name") ?? "";
            if (title.Length == 0) continue;
            var date = Get("release_date") ?? Get("first_air_date") ?? "";
            long? year = date.Length >= 4 && int.TryParse(date.AsSpan(0, 4), NumberStyles.None, CultureInfo.InvariantCulture, out var y) ? y : null;
            list.Add(new TrendingEntry(rank, type, title, Get("original_title") ?? Get("original_name"), year));
        }
        return list;
    }

    /// <summary>The request for one list. A v3 key goes in the address, a v4 read token (it starts "eyJ") in a header. The key is never logged.</summary>
    public static (string Url, Dictionary<string, string>? Headers) Request(string type, string key)
        => key.StartsWith("eyJ", StringComparison.Ordinal)
            ? ($"https://api.themoviedb.org/3/trending/{type}/week", new Dictionary<string, string> { ["Authorization"] = "Bearer " + key })
            : ($"https://api.themoviedb.org/3/trending/{type}/week?api_key={Uri.EscapeDataString(key)}", null);

    /// <summary>Refreshes the cache when it is due and the feature is active. A failure keeps the old cache (until the 180-day cap). Returns the cache to use, or null.</summary>
    public static async Task<Cache?> RefreshAsync(LocalStore store, ITextFetcher fetcher, string? key, bool enabled, DateTimeOffset now, CancellationToken ct = default)
    {
        const string Name = "TmdbTrending";
        if (!enabled || string.IsNullOrWhiteSpace(key)) { Clear(store); return null; }          // off or no key of the person's own: nothing is requested and nothing is kept
        var cache = store.Load<Cache?>(Name, null);
        if (cache is not null && (now.ToUnixTimeMilliseconds() - cache.FetchedAtMs) / 86_400_000 > MaxCacheDays) { Clear(store); cache = null; }
        if (NeedsRefetch(cache, now))
        {
            try
            {
                var k = key.Trim();
                var (mu, mh) = Request("movie", k); var (tu, th) = Request("tv", k);
                var movies = Parse(await fetcher.FetchAsync(mu, mh, ct), "movie");
                var tv = Parse(await fetcher.FetchAsync(tu, th, ct), "tv");
                var entries = Interleave(movies, tv);
                if (entries.Count > 0) { cache = new Cache(now.ToUnixTimeMilliseconds(), entries); store.Save(Name, cache); }
            }
            catch (Exception e) when (e is HttpRequestException or JsonException or InvalidOperationException or TaskCanceledException or IOException) { /* keep what is cached */ }
        }
        return cache;
    }

    public static Cache? Load(LocalStore store) => store.Load<Cache?>("TmdbTrending", null);
    public static void Clear(LocalStore store) { if (Load(store) is not null) store.Save<Cache?>("TmdbTrending", null); }
}
