using System.Text.Json;
using StreamSetu.Core.SmartMix;

namespace StreamSetu.Core;

public sealed record CastMember(long PersonId, string Name, string? Character, string? PhotoPath)
{
    public const string PhotoHost = "image.tmdb.org";
    public string? PhotoUrl => string.IsNullOrEmpty(PhotoPath) ? null : "https://" + PhotoHost + "/t/p/w185" + PhotoPath;
}

public sealed record Credit(string Type, string Title, string? Orig, int? Year);

/// <summary>One title of a person's work that is in the library, once: the copy shown, and how many other versions (languages, qualities, playlists) were folded into it.</summary>
public sealed record PersonTitle(Copy Pick, IReadOnlyList<Copy> Others);

/// <summary>The cast of a title and a person's other titles, from TMDB with the person's own key. What is sent is only the title (and year) of a title the person may see, or a person's id or exact name:
/// a title in a locked, hidden or adult-blocked folder (or with a copy there) is never looked up, so its name never leaves the computer.</summary>
public static class TmdbCast
{
    public const int MaxCast = 20;

    public static string Initials(string name) => Placeholders.Monogram(name);

    private static JsonElement? Results(string json)
    {
        using var doc = JsonDocument.Parse(json);
        return doc.RootElement.TryGetProperty("results", out var r) && r.ValueKind == JsonValueKind.Array ? r.Clone() : null;
    }

    private static string? Str(JsonElement e, string n) => e.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
    private static long? Long(JsonElement e, string n) => e.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt64() : null;

    /// <summary>The first search result's id. The search is by title and year, so the first hit is the title itself.</summary>
    public static long? ParseTitleId(string json) => Results(json) is { } r && r.GetArrayLength() > 0 ? Long(r[0], "id") : null;

    public static List<CastMember> ParseCredits(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var list = new List<CastMember>();
        if (!doc.RootElement.TryGetProperty("cast", out var cast) || cast.ValueKind != JsonValueKind.Array) return list;
        foreach (var c in cast.EnumerateArray())
        {
            var name = Str(c, "name"); var id = Long(c, "id");
            if (string.IsNullOrWhiteSpace(name) || id is null) continue;
            if (list.Any(x => x.PersonId == id)) continue;
            list.Add(new CastMember(id.Value, name!, Str(c, "character") is { Length: > 0 } ch ? ch : null, Str(c, "profile_path")));
            if (list.Count == MaxCast) break;
        }
        return list;
    }

    /// <summary>The person whose name is exactly this one (ignoring case, accents and spacing). A near name is another person.</summary>
    public static long? ParsePersonExact(string json, string name)
    {
        if (Results(json) is not { } r) return null;
        var want = IdentityKey.Normalize(name);
        foreach (var p in r.EnumerateArray())
            if (Str(p, "name") is { } n && IdentityKey.Normalize(n) == want) return Long(p, "id");
        return null;
    }

    public static List<Credit> ParseFilmography(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var list = new List<Credit>();
        if (!doc.RootElement.TryGetProperty("cast", out var cast) || cast.ValueKind != JsonValueKind.Array) return list;
        foreach (var c in cast.EnumerateArray())
        {
            var type = Str(c, "media_type");
            if (type is not ("movie" or "tv")) continue;
            var title = Str(c, "title") ?? Str(c, "name");
            if (string.IsNullOrWhiteSpace(title)) continue;
            var date = Str(c, "release_date") ?? Str(c, "first_air_date") ?? "";
            int? year = date.Length >= 4 && int.TryParse(date.AsSpan(0, 4), out var y) ? y : null;
            list.Add(new Credit(type, title!, Str(c, "original_title") ?? Str(c, "original_name"), year));
        }
        return list;
    }

    private static async Task<string> GetAsync(ITextFetcher f, string path, string key, CancellationToken ct, params (string, string)[] q)
    {
        var (url, headers) = Tmdb.Get(path, key, q);
        return await f.FetchAsync(url, headers, ct);
    }

    /// <summary>The cast of one title, or null when the title is restricted (nothing is sent), not found, or TMDB cannot be reached.</summary>
    public static async Task<List<CastMember>?> CastOfAsync(ITextFetcher fetcher, string key, PrivacySnapshot visible, Copy copy, CancellationToken ct = default)
    {
        if (!visible.ItemOk(copy) || copy.Item.Kind == Kind.Live) return null;               // checked before any request is made
        var type = copy.Item.Kind == Kind.Series ? "tv" : "movie";
        var title = IdentityKey.Make(copy.Item.Title) is { Length: > 0 } ? CleanTitle(copy.Item.Title) : copy.Item.Title;
        try
        {
            var q = new List<(string, string)> { ("query", title) };
            if (IdentityDerive.Year(copy.Item.Year, copy.Item.Title) is { } year) q.Add((type == "tv" ? "first_air_date_year" : "year", year.ToString()));
            var id = ParseTitleId(await GetAsync(fetcher, "/search/" + type, key, ct, q.ToArray()));
            if (id is null) return null;
            return ParseCredits(await GetAsync(fetcher, $"/{type}/{id}/credits", key, ct));
        }
        catch (Exception e) when (e is HttpRequestException or JsonException or InvalidOperationException or TaskCanceledException or IOException) { return null; }
    }

    /// <summary>The title as TMDB knows it: year, quality and language words are not part of it ("Dune (2021) 4K" is "Dune").</summary>
    public static string CleanTitle(string title)
    {
        var words = IdentityKey.Make(title);
        return words.Length == 0 ? title : words;
    }

    /// <summary>The person's titles: the id first, found from the exact name when it is not known. Only the person (id or name) is sent.</summary>
    public static async Task<List<Credit>> FilmographyAsync(ITextFetcher fetcher, string key, CastMember person, CancellationToken ct = default)
    {
        try
        {
            var id = person.PersonId;
            if (id <= 0) id = ParsePersonExact(await GetAsync(fetcher, "/search/person", key, ct, ("query", person.Name)), person.Name) ?? 0;
            if (id <= 0) return new List<Credit>();
            return ParseFilmography(await GetAsync(fetcher, $"/person/{id}/combined_credits", key, ct));
        }
        catch (Exception e) when (e is HttpRequestException or JsonException or InvalidOperationException or TaskCanceledException or IOException) { return new List<Credit>(); }
    }

    /// <summary>The credits that are in the library, each title once. Copies of the same title (other languages, qualities, playlists) are folded into one entry, the preferred copy shown;
    /// anything restricted is left out. Newest first.</summary>
    public static List<PersonTitle> InLibrary(IEnumerable<Credit> credits, IEnumerable<Copy> all, PrivacySnapshot visible, CanonicalPick.Context context)
    {
        var index = new Dictionary<(Kind, string), List<(Copy Copy, DerivedIdentity Id)>>();
        foreach (var c in all)
        {
            if (c.Item.Kind == Kind.Live || !visible.ItemOk(c)) continue;
            var d = IdentityDerive.Derive(c.Item.Title, c.Item.Group, c.Item.Year, c.Item.Kind);
            var k = (c.Item.Kind, d.Key);
            if (!index.TryGetValue(k, out var l)) index[k] = l = new();
            l.Add((c, d));
        }
        var seen = new HashSet<string>(); var found = new List<(PersonTitle T, int Year)>();
        foreach (var credit in credits)
        {
            var kind = credit.Type == "tv" ? Kind.Series : Kind.Movie;
            var names = new[] { credit.Title, credit.Orig }.Where(n => !string.IsNullOrEmpty(n)).Select(n => IdentityKey.Make(n!)).Distinct();
            var members = new List<(Copy Copy, DerivedIdentity Id)>();
            foreach (var n in names)
                if (index.TryGetValue((kind, n), out var l))
                    members.AddRange(l.Where(m => credit.Year is null || m.Id.Year is null || Math.Abs(credit.Year.Value - m.Id.Year.Value) <= 1));
            members = members.DistinctBy(m => m.Copy.Key).ToList();
            if (members.Count == 0) continue;
            var ordered = CanonicalPick.Ordered(members.Select(m => new IdentityMember(m.Copy.Key, m.Copy.PlaylistId, m.Id.Language, m.Id.QualityRank, m.Id.IsCam, m.Id.Year, m.Copy.Item.Added?.ToUnixTimeSeconds() ?? 0)), context).Select(m => m.ItemId).ToList();
            var copies = ordered.Select(id => members.First(m => m.Copy.Key == id).Copy).ToList();
            if (!seen.Add(copies[0].Key)) continue;                                   // two credits that name the same title
            found.Add((new PersonTitle(copies[0], copies.Skip(1).ToList()), credit.Year ?? 0));
        }
        return found.OrderByDescending(f => f.Year).Select(f => f.T).ToList();
    }
}
