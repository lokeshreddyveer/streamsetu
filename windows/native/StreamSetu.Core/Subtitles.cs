using System.Globalization;
using System.Text.Json;

namespace StreamSetu.Core;

public sealed record SubtitleCandidate(string FileId, string Release, string Language, int Downloads, bool HashMatch, string? Title, int? Year, bool HearingImpaired);
public sealed record RankedSubtitle(SubtitleCandidate Candidate, int Score, string Reason);

/// <summary>OpenSubtitles with the person's own free key. Results are ranked by how likely each is to match, each with the reason, and automatic loading takes only a confident match.</summary>
public static class Subtitles
{
    public const string Host = "https://api.opensubtitles.com/api/v1";
    /// <summary>Automatic subtitles load only at or above this score: an exact file match, or the same title and year in the right language.</summary>
    public const int ConfidentScore = 100;

    public static IReadOnlyDictionary<string, string> Headers(string apiKey, string? token = null)
    {
        var h = new Dictionary<string, string> { ["Api-Key"] = apiKey, ["User-Agent"] = "StreamSetu v0.1", ["Accept"] = "application/json" };
        if (token is not null) h["Authorization"] = "Bearer " + token;
        return h;
    }

    public static string SearchUrl(string title, int? year, string language)
        => $"{Host}/subtitles?query={Xtream.EncodeComponent(Tags.Normalize(title))}{(year is { } y ? "&year=" + y : "")}&languages={Xtream.EncodeComponent(language.ToLowerInvariant())}&order_by=download_count";

    public static List<SubtitleCandidate> ParseSearch(string json)
    {
        JsonElement root;
        try { root = JsonDocument.Parse(json).RootElement; } catch (JsonException) { throw new InvalidOperationException("OpenSubtitles answered in a form StreamSetu does not understand."); }
        var list = new List<SubtitleCandidate>();
        if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array) return list;
        foreach (var d in data.EnumerateArray().Take(200))
        {
            if (!d.TryGetProperty("attributes", out var a) || a.ValueKind != JsonValueKind.Object) continue;
            var file = a.TryGetProperty("files", out var files) && files.ValueKind == JsonValueKind.Array ? files.EnumerateArray().Select(f => f.TryGetProperty("file_id", out var id) ? id.GetRawText().Trim('"') : null).FirstOrDefault(x => !string.IsNullOrEmpty(x)) : null;
            if (file is null) continue;
            string? Str(JsonElement o, string n) => o.ValueKind == JsonValueKind.Object && o.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
            int? Int(JsonElement o, string n) => o.ValueKind == JsonValueKind.Object && o.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var i) ? i : null;
            bool Bool(JsonElement o, string n) => o.ValueKind == JsonValueKind.Object && o.TryGetProperty(n, out var v) && v.ValueKind == JsonValueKind.True;
            var feature = a.TryGetProperty("feature_details", out var fd) ? fd : default;
            list.Add(new SubtitleCandidate(file, Str(a, "release") ?? "", Str(a, "language") ?? "", Int(a, "download_count") ?? 0, Bool(a, "moviehash_match"), Str(feature, "title") ?? Str(feature, "movie_name"), Int(feature, "year"), Bool(a, "hearing_impaired")));
        }
        return list;
    }

    public static List<RankedSubtitle> Rank(IEnumerable<SubtitleCandidate> candidates, string title, int? year, string language)
    {
        var wanted = Tags.Normalize(title);
        return candidates.Select(c =>
        {
            int score = 0; var why = new List<string>();
            if (c.HashMatch) { score += 100; why.Add("matches this exact file"); }
            if (c.Title is not null && Tags.Normalize(c.Title) == wanted) { score += 60; why.Add("same title"); }
            else if (c.Title is not null) { score -= 40; why.Add("different title"); }
            if (year is { } y && c.Year == y) { score += 30; why.Add("same year"); }
            if (string.Equals(c.Language, language, StringComparison.OrdinalIgnoreCase)) { score += 20; why.Add("your language"); } else { score -= 100; why.Add("another language"); }
            if (c.Downloads > 0) { score += (int)Math.Min(10, Math.Log10(c.Downloads + 1) * 2); }
            if (c.HearingImpaired) { score -= 5; why.Add("for the hard of hearing"); }
            return new RankedSubtitle(c, score, string.Join(", ", why));
        }).OrderByDescending(r => r.Score).ThenByDescending(r => r.Candidate.Downloads).ToList();
    }

    /// <summary>The one subtitle to load without asking, or null when nothing is confident enough.</summary>
    public static RankedSubtitle? Confident(IEnumerable<RankedSubtitle> ranked) => ranked.FirstOrDefault(r => r.Score >= ConfidentScore);

    public static string LoginBody(string user, string pass) => JsonSerializer.Serialize(new { username = user, password = pass });
    public static string DownloadBody(string fileId) => JsonSerializer.Serialize(new { file_id = long.TryParse(fileId, NumberStyles.None, CultureInfo.InvariantCulture, out var n) ? n : 0 });

    public static string? ParseToken(string json) => Field(json, "token");
    public static string? ParseLink(string json) => Field(json, "link") is { } l && Uri.TryCreate(l, UriKind.Absolute, out var u) && u.Scheme == Uri.UriSchemeHttps ? l : null;

    private static string? Field(string json, string name)
    {
        try { var r = JsonDocument.Parse(json).RootElement; return r.ValueKind == JsonValueKind.Object && r.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null; }
        catch (JsonException) { return null; }
    }
}
