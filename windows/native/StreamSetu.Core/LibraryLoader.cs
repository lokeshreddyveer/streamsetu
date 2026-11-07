using System.Text.Json;

namespace StreamSetu.Core;

/// <summary>Where a password is kept. On Windows this is Credential Manager; tests use memory.</summary>
public interface ISecretStore
{
    void Set(string key, string value);
    string? Get(string key);
    void Delete(string key);
}

public sealed class MemorySecretStore : ISecretStore
{
    private readonly Dictionary<string, string> _values = new();
    public void Set(string key, string value) => _values[key] = value;
    public string? Get(string key) => _values.GetValueOrDefault(key);
    public void Delete(string key) => _values.Remove(key);
}

/// <summary>Fetches the text of a web address. <see cref="SafeHttp"/> is the real one; tests give a fake.</summary>
public interface ITextFetcher
{
    Task<string> FetchAsync(string url, CancellationToken ct = default);
    /// <summary>With request headers (a token, or Basic authentication) and, for WebDAV, another method and a body.</summary>
    Task<string> FetchAsync(string url, IReadOnlyDictionary<string, string>? headers, CancellationToken ct = default, string method = "GET", string? body = null);
}

public sealed class SafeTextFetcher(SafeHttp http) : ITextFetcher
{
    public Task<string> FetchAsync(string url, CancellationToken ct = default) => http.FetchTextAsync(url, ct: ct);
    public Task<string> FetchAsync(string url, IReadOnlyDictionary<string, string>? headers, CancellationToken ct = default, string method = "GET", string? body = null)
        => http.FetchTextAsync(url, ct: ct, headers: headers, method: new HttpMethod(method), body: body);
}

public static class Auth
{
    public static IReadOnlyDictionary<string, string> Basic(string user, string pass)
        => new Dictionary<string, string> { ["Authorization"] = "Basic " + Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(user + ":" + pass)) };
}

public sealed record LoadedLibrary(Library Library, Account? Account, IReadOnlyList<Item> SeriesIndex);

/// <summary>Turns a saved connection into a library the screens can show.</summary>
public sealed class LibraryLoader(ITextFetcher fetcher, ISecretStore secrets)
{
    public static string SecretKey(string playlistId) => "playlist:" + playlistId;

    private static JsonElement Parse(string json)
    {
        try { return JsonDocument.Parse(json).RootElement.Clone(); }
        catch (JsonException) { throw new InvalidOperationException("The server answered, but not in a form StreamSetu understands. Check the address."); }
    }

    /// <summary>Checks a login and returns the account, without loading any channels. Used by "Test".</summary>
    public async Task<Account> TestXtreamAsync(string address, string user, string pass, CancellationToken ct = default)
        => Xtream.ParseAccount(Parse(await fetcher.FetchAsync(Xtream.ApiUrl(address, user, pass), ct)));

    private string Secret(Playlist p, string? given) => given ?? secrets.Get(p.SecretRef ?? SecretKey(p.Id))
        ?? throw new InvalidOperationException("The saved password for this connection could not be found. Edit the connection and enter it again.");

    public const long MaxPlaylistFileBytes = 100L * 1024 * 1024;

    /// <summary>An M3U link, or a playlist file on this computer (chosen by the person in a file picker).</summary>
    private async Task<string> ReadPlaylistTextAsync(string address, CancellationToken ct)
    {
        if (Uri.TryCreate(address, UriKind.Absolute, out var u) && (u.Scheme == Uri.UriSchemeHttp || u.Scheme == Uri.UriSchemeHttps)) return await fetcher.FetchAsync(address, ct);
        var info = new FileInfo(address);
        if (!info.Exists) throw new InvalidOperationException("That playlist file could not be found.");
        if (info.Length > MaxPlaylistFileBytes) throw new InvalidOperationException("That playlist file is larger than any playlist should be.");
        return await File.ReadAllTextAsync(address, ct);
    }

    private static LoadedLibrary Wrap(Library lib) => new(lib, null, lib.Series);
    private static string Host(Playlist p) => Xtream.NormalizeHost(p.Address);

    private async Task<Connectors.ServerUser> MediaUserAsync(Playlist p, string key, CancellationToken ct)
    {
        var users = Connectors.MediaUsers(await fetcher.FetchAsync($"{Host(p)}/Users?api_key={Xtream.EncodeComponent(key)}", ct));
        return users.FirstOrDefault(u => string.Equals(u.Name, p.Username, StringComparison.OrdinalIgnoreCase)) ?? users.FirstOrDefault() ?? throw new InvalidOperationException("The server has no users for this key.");
    }

    /// <param name="passwordGiven">For testing a connection that is not saved yet; otherwise the password comes from the secret store.</param>
    public async Task<LoadedLibrary> LoadAsync(Playlist playlist, CancellationToken ct = default, string? passwordGiven = null)
    {
        var lib = new Library();
        switch (playlist.Kind)
        {
            case PlaylistKind.M3u:
                return Wrap(M3u.ToLibrary(M3u.Parse(await ReadPlaylistTextAsync(playlist.Address, ct))));

            case PlaylistKind.HdHomeRun:
                lib.Live.AddRange(Connectors.HdHomeRun(await fetcher.FetchAsync(Host(playlist) + "/lineup.json", ct)));
                return Wrap(lib);

            case PlaylistKind.TvHeadend:
            {
                var pass = Secret(playlist, passwordGiven); var user = playlist.Username ?? "";
                var text = await fetcher.FetchAsync(Host(playlist) + "/playlist/channels.m3u", Auth.Basic(user, pass), ct);
                return Wrap(M3u.ToLibrary(Connectors.TvHeadend(playlist.Address, user, pass, text)));
            }

            case PlaylistKind.Enigma2:
                lib.Live.AddRange(Connectors.Enigma2(playlist.Address, await fetcher.FetchAsync(Host(playlist) + "/web/getallservices", ct)));
                return Wrap(lib);

            case PlaylistKind.Jellyfin:
            case PlaylistKind.Emby:
            {
                var key = Secret(playlist, passwordGiven); var user = await MediaUserAsync(playlist, key, ct);
                lib.Movies.AddRange(Connectors.MediaItems(playlist.Address, key, await fetcher.FetchAsync(Connectors.MediaItemsUrl(playlist.Address, user.Id, key, "Movie"), ct), Kind.Movie));
                lib.Series.AddRange(Connectors.MediaItems(playlist.Address, key, await fetcher.FetchAsync(Connectors.MediaItemsUrl(playlist.Address, user.Id, key, "Series"), ct), Kind.Series));
                return Wrap(lib);
            }

            case PlaylistKind.Plex:
            {
                var token = Secret(playlist, passwordGiven);
                var sections = Connectors.PlexSections(await fetcher.FetchAsync(Connectors.PlexUrl(playlist.Address, "/library/sections", token), Connectors.PlexHeaders, ct));
                foreach (var s in sections)
                {
                    var items = Connectors.PlexItems(playlist.Address, token, await fetcher.FetchAsync(Connectors.PlexUrl(playlist.Address, $"/library/sections/{Xtream.EncodeComponent(s.Key)}/all", token), Connectors.PlexHeaders, ct), s);
                    (s.Kind == Kind.Movie ? lib.Movies : lib.Series).AddRange(items);
                }
                return Wrap(lib);
            }

            case PlaylistKind.Stalker:
                return await new StalkerClient(fetcher).LoadAsync(playlist, Secret(playlist, passwordGiven), ct);

            case PlaylistKind.WebDav:
                return Wrap(M3u.ToLibrary(await WebDavAsync(playlist, passwordGiven, ct)));

            case PlaylistKind.LocalFolder:
                return Wrap(M3u.ToLibrary(await Task.Run(() => LocalFiles.Scan(playlist.Address), ct)));
        }

        var user0 = playlist.Username ?? "";
        var pass0 = Secret(playlist, passwordGiven);
        return await LoadXtreamAsync(playlist, user0, pass0, ct);
    }

    /// <summary>Walks a WebDAV server a folder at a time (three levels deep, at most 500 folders) and lists its video files.</summary>
    private async Task<List<Item>> WebDavAsync(Playlist p, string? passwordGiven, CancellationToken ct)
    {
        var user = p.Username ?? ""; var pass = string.IsNullOrEmpty(user) ? "" : Secret(p, passwordGiven);
        var headers = new Dictionary<string, string> { ["Depth"] = "1" };
        if (user.Length > 0) foreach (var kv in Auth.Basic(user, pass)) headers[kv.Key] = kv.Value;
        var root = new Uri(p.Address.TrimEnd('/') + "/");
        var items = new List<Item>(); var queue = new Queue<(Uri Url, int Depth, string Group)>(); queue.Enqueue((root, 0, "")); int folders = 0;
        while (queue.Count > 0 && folders++ < 500 && items.Count < Connectors.MaxItems)
        {
            var (url, depth, group) = queue.Dequeue();
            var xml = await fetcher.FetchAsync(url.AbsoluteUri, headers, ct, "PROPFIND", Connectors.PropfindBody);
            foreach (var e in Connectors.DavEntries(xml))
            {
                if (!Uri.TryCreate(url, e.Href, out var target) || target.Host != root.Host) continue;          // an entry that points to another server is not followed
                if (target.AbsolutePath.TrimEnd('/') == url.AbsolutePath.TrimEnd('/')) continue;                 // the folder itself
                var name = Uri.UnescapeDataString(target.Segments.LastOrDefault()?.Trim('/') ?? "");
                if (e.IsFolder) { if (depth < 3) queue.Enqueue((new Uri(target.AbsoluteUri.TrimEnd('/') + "/"), depth + 1, group.Length == 0 ? name : group + "/" + name)); }
                else if (Connectors.IsVideo(name)) items.Add(Connectors.FromFile($"dav:{items.Count}", name, group, user.Length > 0 ? Connectors.WithLogin(target.AbsoluteUri, user, pass) : target.AbsoluteUri));
            }
        }
        return items;
    }

    private async Task<LoadedLibrary> LoadXtreamAsync(Playlist playlist, string user, string pass, CancellationToken ct)
    {
        var account = await TestXtreamAsync(playlist.Address, user, pass, ct);
        if (!account.Active) throw new InvalidOperationException($"This subscription is {account.Status.ToLowerInvariant()}.");

        async Task<JsonElement> Ask(string action) => Parse(await fetcher.FetchAsync(Xtream.ApiUrl(playlist.Address, user, pass, action), ct));
        // Sections are independent: a panel with no series must still show its channels.
        async Task<JsonElement> AskOrEmpty(string action) { try { return await Ask(action); } catch (InvalidOperationException) { return JsonDocument.Parse("[]").RootElement; } }
        var tasks = new[] { "get_live_categories", "get_live_streams", "get_vod_categories", "get_vod_streams", "get_series_categories", "get_series" }.Select(AskOrEmpty).ToArray();
        var r = await Task.WhenAll(tasks);

        var lib = new Library();
        lib.Live.AddRange(Xtream.ParseLive(playlist.Address, user, pass, r[1], r[0]));
        lib.Movies.AddRange(Xtream.ParseMovies(playlist.Address, user, pass, r[3], r[2]));
        lib.Series.AddRange(Xtream.ParseSeriesList(r[5], r[4]));
        return new LoadedLibrary(lib, account, lib.Series);
    }

    /// <summary>The episodes of one series (Xtream), or of a show found in an M3U list.</summary>
    public async Task<List<Episode>> EpisodesAsync(Playlist playlist, LoadedLibrary loaded, Item series, CancellationToken ct = default)
    {
        switch (playlist.Kind)
        {
            case PlaylistKind.M3u: case PlaylistKind.TvHeadend: case PlaylistKind.WebDav: case PlaylistKind.LocalFolder:
                return loaded.Library.Episodes.GetValueOrDefault(series.SeriesId ?? "")?.Select(e => new Episode(e.Id, e.Title, e.Season ?? 1, e.Episode ?? 0, e.Url ?? "", e.Ext)).ToList() ?? new();
            case PlaylistKind.Jellyfin: case PlaylistKind.Emby:
            {
                var key = Secret(playlist, null); var u = await MediaUserAsync(playlist, key, ct);
                return Connectors.MediaEpisodes(playlist.Address, key, await fetcher.FetchAsync(Connectors.MediaEpisodesUrl(playlist.Address, u.Id, key, series.SeriesId ?? ""), ct));
            }
            case PlaylistKind.Plex:
            {
                var token = Secret(playlist, null);
                return Connectors.PlexEpisodes(playlist.Address, token, await fetcher.FetchAsync(Connectors.PlexUrl(playlist.Address, $"/library/metadata/{Xtream.EncodeComponent(series.SeriesId ?? "")}/allLeaves", token), Connectors.PlexHeaders, ct));
            }
            case PlaylistKind.HdHomeRun: case PlaylistKind.Enigma2: case PlaylistKind.Stalker: return new();      // no series lists
        }
        var user = playlist.Username ?? "";
        var pass = Secret(playlist, null);
        var info = Parse(await fetcher.FetchAsync(Xtream.ApiUrl(playlist.Address, user, pass, "get_series_info", new Dictionary<string, string> { ["series_id"] = series.SeriesId ?? "" }), ct));
        return Xtream.ParseEpisodes(playlist.Address, user, pass, info);
    }

    /// <summary>The address to give the player. Almost always the item's own; a Stalker placeholder is turned into a fresh link by asking the portal.</summary>
    public async Task<string> ResolvePlayUrlAsync(Playlist playlist, string url, CancellationToken ct = default)
        => playlist.Kind == PlaylistKind.Stalker && url.StartsWith(StalkerClient.Scheme, StringComparison.Ordinal)
            ? await new StalkerClient(fetcher).ResolveAsync(playlist, Secret(playlist, null), url, ct)
            : url;

    /// <summary>Case-insensitive search over titles and folders.</summary>
    public static List<Item> Search(IEnumerable<Item> items, string query)
    {
        var words = query.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (words.Length == 0) return items.ToList();
        return items.Where(i => words.All(w => i.Title.Contains(w, StringComparison.CurrentCultureIgnoreCase) || i.Group.Contains(w, StringComparison.CurrentCultureIgnoreCase))).ToList();
    }
}
