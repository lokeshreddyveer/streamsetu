using System.Globalization;
using System.Text.Json;
using System.Xml;
using System.Xml.Linq;

namespace StreamSetu.Core;

/// <summary>Reading what each kind of server answers. Everything here is outside data: lists are bounded, XML refuses DTDs, and a wrong shape gives an empty result or a clear error, never a crash.</summary>
public static class Connectors
{
    public const int MaxItems = 200_000;

    private static XDocument LoadXml(string xml)
    {
        var settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersFromEntities = 0 };
        try { using var r = XmlReader.Create(new StringReader(xml), settings); return XDocument.Load(r); }
        catch (XmlException e) { throw new InvalidOperationException("The server answered, but not in a form StreamSetu understands: " + e.Message); }
    }

    private static JsonElement Json(string text)
    {
        try { return JsonDocument.Parse(text).RootElement.Clone(); }
        catch (JsonException) { throw new InvalidOperationException("The server answered, but not in a form StreamSetu understands. Check the address."); }
    }

    private static string? S(JsonElement o, string name) =>
        o.ValueKind == JsonValueKind.Object && o.TryGetProperty(name, out var v) && v.ValueKind is not (JsonValueKind.Null or JsonValueKind.Undefined) ? (v.ValueKind == JsonValueKind.String ? v.GetString() : v.GetRawText()) : null;
    private static double? N(JsonElement o, string name) => double.TryParse(S(o, name), NumberStyles.Float, CultureInfo.InvariantCulture, out var d) && double.IsFinite(d) ? d : null;
    private static IEnumerable<JsonElement> Arr(JsonElement o, string name) => o.ValueKind == JsonValueKind.Object && o.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Array ? v.EnumerateArray() : Enumerable.Empty<JsonElement>();
    private static string Enc(string s) => Xtream.EncodeComponent(s);

    /// <summary>A web address with a login in it, for mpv (which reads such addresses). The app's own downloads never carry one.</summary>
    public static string WithLogin(string url, string user, string pass)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var u)) return url;
        return new UriBuilder(u) { UserName = user, Password = pass }.Uri.AbsoluteUri;
    }

    // ---------- HDHomeRun: /lineup.json ----------
    public static List<Item> HdHomeRun(string lineupJson)
    {
        var list = new List<Item>();
        var root = Json(lineupJson);
        foreach (var c in (root.ValueKind == JsonValueKind.Array ? root.EnumerateArray() : Enumerable.Empty<JsonElement>()).Take(MaxItems))
        {
            var number = S(c, "GuideNumber"); var url = S(c, "URL");
            if (number is null || url is null || !url.StartsWith("http", StringComparison.OrdinalIgnoreCase)) continue;
            list.Add(new Item { Id = "live:" + number, Kind = Kind.Live, Title = S(c, "GuideName") ?? number, Group = "Channels", Url = url });
        }
        return list;
    }

    // ---------- TVHeadend: /playlist/channels.m3u, with the login put into the stream addresses ----------
    public static List<Item> TvHeadend(string address, string user, string pass, string m3uText)
    {
        var host = Uri.TryCreate(Xtream.NormalizeHost(address), UriKind.Absolute, out var a) ? a.Host : "";
        return M3u.Parse(m3uText).Select(i => i.Url is not null && Uri.TryCreate(i.Url, UriKind.Absolute, out var u) && u.Host == host ? i with { Url = WithLogin(i.Url, user, pass), Kind = Kind.Live } : i).ToList();
    }

    // ---------- Enigma2: /web/getallservices ----------
    public static List<Item> Enigma2(string address, string xml)
    {
        var host = Uri.TryCreate(Xtream.NormalizeHost(address), UriKind.Absolute, out var a) ? a.Host : "";
        var list = new List<Item>();
        foreach (var bouquet in LoadXml(xml).Descendants("e2bouquet"))
        {
            var group = bouquet.Element("e2servicename")?.Value.Trim() is { Length: > 0 } g ? g : "Channels";
            foreach (var s in bouquet.Element("e2servicelist")?.Elements("e2service") ?? Enumerable.Empty<XElement>())
            {
                var reference = s.Element("e2servicereference")?.Value.Trim(); var name = s.Element("e2servicename")?.Value.Trim();
                // 1:0: is a playable service; 1:7: is a bouquet and 1:64: a divider.
                if (string.IsNullOrEmpty(reference) || string.IsNullOrEmpty(name) || !reference.StartsWith("1:0:", StringComparison.Ordinal)) continue;
                list.Add(new Item { Id = "live:" + reference, Kind = Kind.Live, Title = name, Group = group, Url = $"http://{host}:8001/{reference}" });
                if (list.Count >= MaxItems) return list;
            }
        }
        return list;
    }

    // ---------- Jellyfin and Emby: read with an API key (Dashboard, API keys); the key is the saved password ----------
    public sealed record ServerUser(string Id, string Name);

    public static List<ServerUser> MediaUsers(string json)
        => Json(json).ValueKind == JsonValueKind.Array ? Json(json).EnumerateArray().Select(u => new ServerUser(S(u, "Id") ?? "", S(u, "Name") ?? "")).Where(u => u.Id.Length > 0).ToList() : new();

    public static string MediaItemsUrl(string address, string userId, string key, string type)
        => $"{Xtream.NormalizeHost(address)}/Users/{Enc(userId)}/Items?Recursive=true&IncludeItemTypes={type}&Fields=ProductionYear,CommunityRating,Genres,DateCreated&SortBy=SortName&api_key={Enc(key)}";

    public static List<Item> MediaItems(string address, string key, string json, Kind kind)
    {
        var host = Xtream.NormalizeHost(address); var list = new List<Item>();
        foreach (var it in Arr(Json(json), "Items").Take(MaxItems))
        {
            var id = S(it, "Id"); var name = S(it, "Name");
            if (id is null || name is null) continue;
            var genre = Arr(it, "Genres").Select(g => g.ValueKind == JsonValueKind.String ? g.GetString() : null).FirstOrDefault(g => !string.IsNullOrEmpty(g));
            DateTimeOffset? added = DateTimeOffset.TryParse(S(it, "DateCreated"), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var d) ? d : null;
            list.Add(new Item
            {
                Id = $"{(kind == Kind.Movie ? "movie" : "series")}:{id}", Kind = kind, Title = name, Group = genre ?? (kind == Kind.Movie ? "Movies" : "Series"),
                Year = N(it, "ProductionYear") is { } y ? (int)y : null, Rating = N(it, "CommunityRating") is { } r ? r / 2 : null, Added = added,
                SeriesId = kind == Kind.Series ? id : null, Ext = null,
                Url = kind == Kind.Movie ? $"{host}/Videos/{Enc(id)}/stream?static=true&api_key={Enc(key)}" : null,
            });
        }
        return list;
    }

    public static string MediaEpisodesUrl(string address, string userId, string key, string seriesId)
        => $"{Xtream.NormalizeHost(address)}/Shows/{Enc(seriesId)}/Episodes?UserId={Enc(userId)}&api_key={Enc(key)}";

    public static List<Episode> MediaEpisodes(string address, string key, string json)
    {
        var host = Xtream.NormalizeHost(address);
        return Arr(Json(json), "Items").Select(e => (Id: S(e, "Id"), Name: S(e, "Name"), Season: N(e, "ParentIndexNumber"), Number: N(e, "IndexNumber")))
            .Where(e => e.Id is not null)
            .Select(e => new Episode("episode:" + e.Id, e.Name ?? $"Episode {e.Number}", (int)(e.Season ?? 1), (int)(e.Number ?? 0), $"{host}/Videos/{Enc(e.Id!)}/stream?static=true&api_key={Enc(key)}", null))
            .OrderBy(e => e.Season).ThenBy(e => e.Number).ToList();
    }

    // ---------- Plex: the saved password is the X-Plex-Token; answers are asked for as JSON ----------
    public static readonly IReadOnlyDictionary<string, string> PlexHeaders = new Dictionary<string, string> { ["Accept"] = "application/json" };
    public static string PlexUrl(string address, string path, string token) => $"{Xtream.NormalizeHost(address)}{path}{(path.Contains('?') ? '&' : '?')}X-Plex-Token={Enc(token)}";

    public sealed record PlexSection(string Key, Kind Kind, string Title);
    public static List<PlexSection> PlexSections(string json)
        => Arr(Json(json).ValueKind == JsonValueKind.Object && Json(json).TryGetProperty("MediaContainer", out var mc) ? mc : default, "Directory")
            .Select(d => (Key: S(d, "key"), Type: S(d, "type"), Title: S(d, "title") ?? ""))
            .Where(d => d.Key is not null && d.Type is "movie" or "show")
            .Select(d => new PlexSection(d.Key!, d.Type == "movie" ? Kind.Movie : Kind.Series, d.Title)).ToList();

    public static List<Item> PlexItems(string address, string token, string json, PlexSection section)
    {
        var list = new List<Item>();
        var root = Json(json);
        var metadata = root.ValueKind == JsonValueKind.Object && root.TryGetProperty("MediaContainer", out var mc) ? Arr(mc, "Metadata") : Enumerable.Empty<JsonElement>();
        foreach (var m in metadata.Take(MaxItems))
        {
            var rk = S(m, "ratingKey"); var title = S(m, "title");
            if (rk is null || title is null) continue;
            var part = Arr(m, "Media").SelectMany(x => Arr(x, "Part")).Select(p => S(p, "key")).FirstOrDefault(k => !string.IsNullOrEmpty(k));
            list.Add(new Item
            {
                Id = $"{(section.Kind == Kind.Movie ? "movie" : "series")}:{rk}", Kind = section.Kind, Title = title, Group = section.Title, Year = N(m, "year") is { } y ? (int)y : null,
                Rating = N(m, "rating") is { } r ? r / 2 : null, Added = N(m, "addedAt") is { } t ? DateTimeOffset.FromUnixTimeSeconds((long)t) : null,
                SeriesId = section.Kind == Kind.Series ? rk : null, Url = section.Kind == Kind.Movie && part is not null ? PlexUrl(address, part, token) : null,
            });
        }
        return list;
    }

    public static List<Episode> PlexEpisodes(string address, string token, string json)
    {
        var root = Json(json);
        var metadata = root.ValueKind == JsonValueKind.Object && root.TryGetProperty("MediaContainer", out var mc) ? Arr(mc, "Metadata") : Enumerable.Empty<JsonElement>();
        var list = new List<Episode>();
        foreach (var m in metadata)
        {
            var rk = S(m, "ratingKey"); var part = Arr(m, "Media").SelectMany(x => Arr(x, "Part")).Select(p => S(p, "key")).FirstOrDefault(k => !string.IsNullOrEmpty(k));
            if (rk is null || part is null) continue;
            list.Add(new Episode("episode:" + rk, S(m, "title") ?? "Episode", (int)(N(m, "parentIndex") ?? 1), (int)(N(m, "index") ?? 0), PlexUrl(address, part, token), null));
        }
        return list.OrderBy(e => e.Season).ThenBy(e => e.Number).ToList();
    }

    // ---------- WebDAV: PROPFIND, one folder at a time ----------
    public sealed record DavEntry(string Href, bool IsFolder);
    public const string PropfindBody = "<?xml version=\"1.0\"?><propfind xmlns=\"DAV:\"><prop><resourcetype/><getcontentlength/></prop></propfind>";
    public static readonly string[] VideoExtensions = { ".mp4", ".mkv", ".avi", ".mov", ".m4v", ".ts", ".webm", ".wmv", ".mpg", ".mpeg", ".flv" };

    public static List<DavEntry> DavEntries(string xml)
    {
        XNamespace dav = "DAV:";
        return LoadXml(xml).Descendants(dav + "response").Select(r => new DavEntry(r.Element(dav + "href")?.Value.Trim() ?? "", r.Descendants(dav + "collection").Any())).Where(e => e.Href.Length > 0).ToList();
    }

    public static bool IsVideo(string path) => VideoExtensions.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);

    /// <summary>A movie or episode from a file name: dots and underscores become spaces, the extension goes, and S01E02 numbering makes it a series entry.</summary>
    public static Item FromFile(string id, string fileName, string group, string url)
    {
        var title = Path.GetFileNameWithoutExtension(fileName).Replace('.', ' ').Replace('_', ' ').Trim();
        var kind = M3u.Classify("", group, title) == Kind.Series ? Kind.Series : Kind.Movie;
        var item = new Item { Id = id, Kind = kind, Title = title, Group = string.IsNullOrWhiteSpace(group) ? "Videos" : group, Url = url, Ext = Path.GetExtension(fileName).TrimStart('.').ToLowerInvariant() };
        if (kind == Kind.Series && System.Text.RegularExpressions.Regex.Match(title, @"^(.*?)[\s._-]+S(\d{1,2})[\s._-]*E(\d{1,3})\b", System.Text.RegularExpressions.RegexOptions.IgnoreCase | System.Text.RegularExpressions.RegexOptions.ECMAScript) is { Success: true } m)
            item = item with { Title = m.Groups[1].Value.Trim(), Season = int.Parse(m.Groups[2].Value), Episode = int.Parse(m.Groups[3].Value) };
        return item;
    }
}

/// <summary>Video files in a folder on this computer.</summary>
public static class LocalFiles
{
    public static List<Item> Scan(string folder, int maxFiles = 100_000)
    {
        if (!Directory.Exists(folder)) throw new InvalidOperationException("That folder does not exist.");
        // Links are not followed: a link back up the tree would otherwise list a folder over and over.
        var options = new EnumerationOptions { RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.ReparsePoint | FileAttributes.System, MaxRecursionDepth = 12 };
        var items = new List<Item>(); int n = 0;
        foreach (var file in Directory.EnumerateFiles(folder, "*", options).Where(Connectors.IsVideo).Take(maxFiles).OrderBy(f => f, StringComparer.OrdinalIgnoreCase))
        {
            var rel = Path.GetRelativePath(folder, Path.GetDirectoryName(file) ?? folder);
            items.Add(Connectors.FromFile($"file:{n++}", Path.GetFileName(file), rel == "." ? "" : rel.Replace('\\', '/'), file));
        }
        return items;
    }
}
