using System.Text.Json;
using System.Text.RegularExpressions;

namespace StreamSetu.Core;

/// <summary>Stalker / Ministra portals: the person's portal address and the MAC address of their (virtual) set-top box, which is the saved "password". The portal gives a token for a MAC,
/// lists channels and films, and hands out a fresh stream link each time something is played, so channel addresses here are placeholders (<c>stalker:</c>) that are resolved at play time.</summary>
public sealed class StalkerClient(ITextFetcher fetcher)
{
    public const string Scheme = "stalker:";
    private static readonly Regex MacPattern = new(@"^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$", RegexOptions.ECMAScript);
    public static bool IsMac(string? mac) => mac is not null && MacPattern.IsMatch(mac.Trim());

    /// <summary>The server script: the address as typed if it already names it, otherwise the usual places under the portal's host.</summary>
    public static string LoadUrl(string address)
    {
        var a = address.Trim();
        if (a.Contains("load.php", StringComparison.OrdinalIgnoreCase)) return a.Split('?')[0];
        var host = Xtream.NormalizeHost(a);
        return a.Contains("stalker_portal", StringComparison.OrdinalIgnoreCase) ? $"{host}/stalker_portal/server/load.php" : $"{host}/server/load.php";
    }

    public static IReadOnlyDictionary<string, string> Headers(string mac, string? token)
    {
        var h = new Dictionary<string, string>
        {
            ["Cookie"] = $"mac={mac.Trim()}; stb_lang=en; timezone=UTC",
            ["User-Agent"] = "Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3",
            ["X-User-Agent"] = "Model: MAG250; Link: WiFi",
        };
        if (token is not null) h["Authorization"] = "Bearer " + token;
        return h;
    }

    private static string Query(string loadUrl, string type, string action, string extra = "") => $"{loadUrl}?type={type}&action={action}{extra}&JsHttpRequest=1-xml";

    private static JsonElement Js(string text)
    {
        try
        {
            var root = JsonDocument.Parse(text).RootElement.Clone();
            if (root.ValueKind == JsonValueKind.Object && root.TryGetProperty("js", out var js)) return js;
        }
        catch (JsonException) { }
        throw new InvalidOperationException("The portal answered, but not in a form StreamSetu understands. Check the address.");
    }

    private static string? S(JsonElement o, string name) => o.ValueKind == JsonValueKind.Object && o.TryGetProperty(name, out var v) && v.ValueKind is not (JsonValueKind.Null or JsonValueKind.Undefined) ? (v.ValueKind == JsonValueKind.String ? v.GetString() : v.GetRawText()) : null;

    /// <summary>The token for this MAC. A portal that does not know the MAC answers with an empty or missing token.</summary>
    public async Task<string> HandshakeAsync(string address, string mac, CancellationToken ct = default)
    {
        if (!IsMac(mac)) throw new InvalidOperationException("The MAC address looks like 00:1A:79:12:34:56.");
        var js = Js(await fetcher.FetchAsync(Query(LoadUrl(address), "stb", "handshake", "&token="), Headers(mac, null), ct));
        return S(js, "token") is { Length: > 0 } t ? t : throw new InvalidOperationException("The portal did not accept this MAC address.");
    }

    public async Task<LoadedLibrary> LoadAsync(Playlist p, string mac, CancellationToken ct = default)
    {
        var load = LoadUrl(p.Address);
        var token = await HandshakeAsync(p.Address, mac, ct);
        var headers = Headers(mac, token);
        // Opening the profile is what makes many portals start the session; its answer is not needed.
        try { await fetcher.FetchAsync(Query(load, "stb", "get_profile"), headers, ct); } catch (InvalidOperationException) { }

        var lib = new Library();
        var genres = new Dictionary<string, string>();
        try { foreach (var g in Arr(Js(await fetcher.FetchAsync(Query(load, "itv", "get_genres"), headers, ct)))) if (S(g, "id") is { } id) genres[id] = S(g, "title") ?? "Channels"; } catch (InvalidOperationException) { }
        foreach (var c in Arr(Js(await fetcher.FetchAsync(Query(load, "itv", "get_all_channels"), headers, ct)), "data").Take(Connectors.MaxItems))
        {
            var id = S(c, "id"); var name = S(c, "name"); var cmd = S(c, "cmd");
            if (id is null || name is null || cmd is null) continue;
            lib.Live.Add(new Item { Id = "live:" + id, Kind = Kind.Live, Title = name, Group = S(c, "tv_genre_id") is { } gid && genres.TryGetValue(gid, out var gn) ? gn : "Channels", Logo = S(c, "logo") is { Length: > 0 } logo && logo.StartsWith("http") ? logo : null, EpgId = null, Url = Scheme + "itv:" + Uri.EscapeDataString(cmd) });
        }

        // Films, a page at a time (a portal lists perhaps 14 to 100 per page); stop after 400 pages or when a page is empty.
        for (int page = 1; page <= 400; page++)
        {
            JsonElement js;
            try { js = Js(await fetcher.FetchAsync(Query(load, "vod", "get_ordered_list", $"&p={page}"), headers, ct)); } catch (InvalidOperationException) { break; }
            var items = Arr(js, "data").ToList();
            if (items.Count == 0) break;
            foreach (var m in items)
            {
                var id = S(m, "id"); var name = S(m, "name"); var cmd = S(m, "cmd");
                if (id is null || name is null || cmd is null) continue;
                lib.Movies.Add(new Item { Id = "movie:" + id, Kind = Kind.Movie, Title = name, Group = "Movies", Year = int.TryParse(S(m, "year"), out var y) ? y : null, Plot = S(m, "description"), Url = Scheme + "vod:" + Uri.EscapeDataString(cmd) });
            }
            if (lib.Movies.Count >= Connectors.MaxItems) break;
        }
        return new LoadedLibrary(lib, null, lib.Series);
    }

    private static IEnumerable<JsonElement> Arr(JsonElement o, string? name = null)
    {
        var a = name is null ? o : o.ValueKind == JsonValueKind.Object && o.TryGetProperty(name, out var v) ? v : default;
        return a.ValueKind == JsonValueKind.Array ? a.EnumerateArray() : Enumerable.Empty<JsonElement>();
    }

    /// <summary>The real address for a <c>stalker:</c> placeholder: asks the portal for a link now, since links are short-lived. The portal answers with something like "ffmpeg http://…"; the player is only given the address.</summary>
    public async Task<string> ResolveAsync(Playlist p, string mac, string placeholder, CancellationToken ct = default)
    {
        if (!placeholder.StartsWith(Scheme, StringComparison.Ordinal)) return placeholder;
        var rest = placeholder[Scheme.Length..];
        var type = rest.StartsWith("vod:") ? "vod" : "itv";
        var cmd = Uri.UnescapeDataString(rest[(rest.IndexOf(':') + 1)..]);
        var load = LoadUrl(p.Address);
        var token = await HandshakeAsync(p.Address, mac, ct);
        var js = Js(await fetcher.FetchAsync(Query(load, type, "create_link", "&cmd=" + Uri.EscapeDataString(cmd)), Headers(mac, token), ct));
        var link = S(js, "cmd")?.Trim() ?? "";
        var space = link.IndexOf(' ');
        if (space > 0 && !link.StartsWith("http", StringComparison.OrdinalIgnoreCase)) link = link[(space + 1)..].Trim();       // "ffmpeg http://…" or "auto http://…"
        if (!Uri.TryCreate(link, UriKind.Absolute, out var u) || (u.Scheme != Uri.UriSchemeHttp && u.Scheme != Uri.UriSchemeHttps)) throw new InvalidOperationException("The portal did not give a link to play this.");
        return link;
    }
}
