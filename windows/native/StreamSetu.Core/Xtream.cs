using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace StreamSetu.Core;

public sealed record Account(bool Active, string Status, DateTimeOffset? Expires, int? MaxConnections)
{
    public int? DaysLeft(DateTimeOffset now) => Expires is { } e ? (int)Math.Floor((e - now).TotalDays) : null;

    /// <summary>A warning from a week before the subscription ends, and after; null when there is nothing to say.</summary>
    public string? Warning(DateTimeOffset now) => DaysLeft(now) switch
    {
        null => null,
        < 0 => "This subscription has ended.",
        0 => "This subscription ends today.",
        1 => "This subscription ends tomorrow.",
        <= 7 and var d => $"This subscription ends in {d} days.",
        _ => null,
    };
}

/// <summary>Xtream Codes panels: the addresses to ask, and reading what they answer.</summary>
public static class Xtream
{
    private static readonly Regex HasScheme = new(@"^[a-z][a-z0-9+.-]*://", RegexOptions.ECMAScript | RegexOptions.IgnoreCase);
    private static readonly Regex Divider = new(@"^[#=*-]{3,}", RegexOptions.ECMAScript);

    /// <summary>Adds http:// when missing and drops the trailing slash and any path such as /c/ or /player_api.php that people paste by mistake.</summary>
    public static string NormalizeHost(string address)
    {
        var a = address.Trim();
        if (!HasScheme.IsMatch(a)) a = "http://" + a;
        return Uri.TryCreate(a, UriKind.Absolute, out var u) ? u.GetLeftPart(UriPartial.Authority) : a.TrimEnd('/');
    }

    // The two encoders below match the browser's, so addresses are the same as the ones the other apps build.
    private static string Encode(string s, string keep, bool spaceAsPlus)
    {
        var sb = new StringBuilder();
        foreach (var b in Encoding.UTF8.GetBytes(s))
        {
            char c = (char)b;
            if (b < 128 && (char.IsAsciiLetterOrDigit(c) || keep.Contains(c))) sb.Append(c);
            else if (b == ' ' && spaceAsPlus) sb.Append('+');
            else sb.Append('%').Append(b.ToString("X2"));
        }
        return sb.ToString();
    }
    /// <summary>Like encodeURIComponent.</summary>
    public static string EncodeComponent(string s) => Encode(s, "-_.!~*'()", false);
    private static string EncodeForm(string s) => Encode(s, "-_.*", true);

    public static string ApiUrl(string address, string user, string pass, string? action = null, IReadOnlyDictionary<string, string>? extra = null)
    {
        var pairs = new List<(string, string)> { ("username", user), ("password", pass) };
        if (action is not null) pairs.Add(("action", action));
        if (extra is not null) foreach (var kv in extra) pairs.Add((kv.Key, kv.Value));
        var query = string.Join("&", pairs.Select(p => $"{EncodeForm(p.Item1)}={EncodeForm(p.Item2)}"));
        return $"{NormalizeHost(address)}/player_api.php?{query}";
    }

    /// <summary>A past programme of a channel, from the provider's archive: /timeshift/user/pass/minutes/yyyy-MM-dd:HH-mm/id.ts. The time is the provider's (UTC unless it says otherwise).</summary>
    public static string CatchupUrl(string address, string user, string pass, string streamId, DateTimeOffset start, int minutes)
        => $"{NormalizeHost(address)}/timeshift/{EncodeComponent(user)}/{EncodeComponent(pass)}/{minutes}/{start.UtcDateTime:yyyy-MM-dd:HH-mm}/{EncodeComponent(streamId)}.ts";

    private static DateTimeOffset? Epoch(string? s)
    {
        if (Num(s) is not { } n) return null;
        try { return n > 1e11 ? DateTimeOffset.FromUnixTimeMilliseconds((long)n) : DateTimeOffset.FromUnixTimeSeconds((long)n); } catch (ArgumentOutOfRangeException) { return null; }
    }

    public static string StreamUrl(string address, string user, string pass, Kind kind, string id, string? ext = null)
    {
        var e = !string.IsNullOrEmpty(ext) ? ext.TrimStart('.') : kind == Kind.Live ? "m3u8" : "mp4";
        var folder = kind switch { Kind.Live => "live", Kind.Movie => "movie", _ => "series" };
        return $"{NormalizeHost(address)}/{folder}/{EncodeComponent(user)}/{EncodeComponent(pass)}/{EncodeComponent(id)}.{e}";
    }

    // --- Reading answers. Panels return false, {} or null for an empty section, and sometimes key a list by id. ---

    private static string? Str(JsonElement o, string name)
    {
        if (o.ValueKind != JsonValueKind.Object || !o.TryGetProperty(name, out var v)) return null;
        return v.ValueKind switch
        {
            JsonValueKind.Null or JsonValueKind.Undefined => null,
            JsonValueKind.String => v.GetString() is { Length: > 0 } s ? s : null,
            JsonValueKind.True => "true",
            JsonValueKind.False => "false",
            _ => v.GetRawText(),
        };
    }

    private static double? Num(string? s) => s is not null && double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var n) && double.IsFinite(n) && n > 0 ? n : null;
    private static double? Num(JsonElement o, string name) => Num(Str(o, name));
    /// <summary>The first of these fields that is present and not null (an empty string counts as present, like <c>??</c>).</summary>
    private static string? First(JsonElement o, params string[] names)
    {
        foreach (var n in names)
            if (o.ValueKind == JsonValueKind.Object && o.TryGetProperty(n, out var v) && v.ValueKind != JsonValueKind.Null)
                return v.ValueKind == JsonValueKind.String ? v.GetString() : v.GetRawText();
        return null;
    }
    private static int? Year(JsonElement o, params string[] names)
    {
        var s = First(o, names) ?? "";
        return Num(s.Length > 4 ? s[..4] : s) is { } y ? (int)y : null;
    }

    public static IEnumerable<JsonElement> AsList(JsonElement v)
    {
        if (v.ValueKind == JsonValueKind.Array) return v.EnumerateArray().ToList();
        if (v.ValueKind == JsonValueKind.Object) return v.EnumerateObject().Select(p => p.Value).Where(x => x.ValueKind == JsonValueKind.Object).ToList();
        return Array.Empty<JsonElement>();
    }

    public static Account ParseAccount(JsonElement json)
    {
        if (json.ValueKind != JsonValueKind.Object || !json.TryGetProperty("user_info", out var info) || info.ValueKind != JsonValueKind.Object)
            throw new InvalidOperationException("The server did not accept the login.");
        if (Str(info, "auth") == "0") throw new InvalidOperationException("The server refused the login. Check the user name and password.");
        var status = Str(info, "status") ?? "Active";
        DateTimeOffset? expires = Num(info, "exp_date") is { } e ? DateTimeOffset.FromUnixTimeSeconds((long)e) : null;
        return new Account(string.Equals(status, "active", StringComparison.OrdinalIgnoreCase), status, expires, Num(info, "max_connections") is { } m ? (int)m : null);
    }

    private static Dictionary<string, string> Categories(JsonElement v)
    {
        var map = new Dictionary<string, string>();
        foreach (var c in AsList(v)) if (Str(c, "category_id") is { } id) map[id] = Str(c, "category_name") ?? $"Category {id}";
        return map;
    }
    private static string Folder(Dictionary<string, string> names, JsonElement s, string fallback) => Str(s, "category_id") is { } id && names.TryGetValue(id, out var n) ? n : fallback;

    public static List<Item> ParseLive(string address, string user, string pass, JsonElement streams, JsonElement cats)
    {
        var names = Categories(cats); var list = new List<Item>();
        foreach (var s in AsList(streams))
        {
            var id = Str(s, "stream_id"); var name = Str(s, "name");
            if (id is null || name is null || Divider.IsMatch(name.Trim())) continue;           // divider rows some providers add
            list.Add(new Item { Id = $"live:{id}", Kind = Kind.Live, Title = name, Group = Folder(names, s, "Channels"), Logo = Str(s, "stream_icon"), EpgId = Str(s, "epg_channel_id"),
                Url = StreamUrl(address, user, pass, Kind.Live, id, "m3u8") });
        }
        return list;
    }

    public static List<Item> ParseMovies(string address, string user, string pass, JsonElement streams, JsonElement cats)
    {
        var names = Categories(cats); var list = new List<Item>();
        foreach (var s in AsList(streams))
        {
            var id = Str(s, "stream_id"); var name = Str(s, "name");
            if (id is null || name is null) continue;
            var ext = Str(s, "container_extension") ?? "mp4";
            list.Add(new Item { Id = $"movie:{id}", Kind = Kind.Movie, Title = name, Group = Folder(names, s, "Movies"), Logo = Str(s, "stream_icon"),
                Rating = Num(First(s, "rating_5based", "rating")), Year = Year(s, "year", "releasedate"), Ext = ext, Added = Epoch(Str(s, "added")), Url = StreamUrl(address, user, pass, Kind.Movie, id, ext) });
        }
        return list;
    }

    public static List<Item> ParseSeriesList(JsonElement streams, JsonElement cats)
    {
        var names = Categories(cats); var list = new List<Item>();
        foreach (var s in AsList(streams))
        {
            var id = Str(s, "series_id"); var name = Str(s, "name");
            if (id is null || name is null) continue;
            list.Add(new Item { Id = $"series:{id}", Kind = Kind.Series, Title = name, Group = Folder(names, s, "Series"), Logo = Str(s, "cover"),
                Rating = Num(First(s, "rating_5based", "rating")), Year = Year(s, "year", "releaseDate"), Plot = Str(s, "plot"), SeriesId = id, Added = Epoch(Str(s, "last_modified")) });
        }
        return list;
    }

    /// <summary>The episodes of one series, season by season, as get_series_info returns them.</summary>
    public static List<Episode> ParseEpisodes(string address, string user, string pass, JsonElement info)
    {
        var list = new List<Episode>();
        if (info.ValueKind != JsonValueKind.Object || !info.TryGetProperty("episodes", out var eps)) return list;
        var seasons = new List<(string Season, JsonElement Items)>();
        if (eps.ValueKind == JsonValueKind.Array) { int i = 0; foreach (var l in eps.EnumerateArray()) seasons.Add(((++i).ToString(CultureInfo.InvariantCulture), l)); }
        else if (eps.ValueKind == JsonValueKind.Object) foreach (var p in eps.EnumerateObject()) seasons.Add((p.Name, p.Value));
        foreach (var (season, items) in seasons)
            foreach (var e in AsList(items))
            {
                var id = Str(e, "id"); if (id is null) continue;
                var ext = Str(e, "container_extension") ?? "mp4";
                var number = Str(e, "episode_num");
                list.Add(new Episode($"episode:{id}", Str(e, "title") ?? $"Episode {number ?? ""}".Trim(), (int)(Num(e, "season") ?? Num(season) ?? 1), (int)(Num(number) ?? 0),
                    StreamUrl(address, user, pass, Kind.Series, id, ext), ext));
            }
        return list.OrderBy(e => e.Season).ThenBy(e => e.Number).ToList();
    }
}
