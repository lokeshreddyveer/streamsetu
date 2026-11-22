using Microsoft.UI.Xaml;
using StreamSetu.Core;
using StreamSetu.Core.SmartMix;
using Windows.Security.Credentials;

namespace StreamSetu.App;

/// <summary>Passwords live in Windows Credential Manager, never in the app's own files.</summary>
internal sealed class CredentialManagerSecrets : ISecretStore
{
    private const string Resource = "StreamSetu";
    private readonly PasswordVault _vault = new();

    public void Set(string key, string value) { Delete(key); _vault.Add(new PasswordCredential(Resource, key, value)); }

    public string? Get(string key)
    {
        try { var c = _vault.Retrieve(Resource, key); c.RetrievePassword(); return c.Password; }
        catch (Exception) { return null; }               // not found, or the vault is unavailable: the caller asks the person to enter it again
    }

    public void Delete(string key)
    {
        try { _vault.Remove(_vault.Retrieve(Resource, key)); }
        catch (Exception) { /* nothing saved under that name */ }
    }
}

/// <summary>What every screen shares. One of each, made when the program starts.</summary>
internal static class AppServices
{
    public const string UserAgent = "StreamSetu/0.1 (Windows)";

    /// <summary>Connections, profiles and settings: shared by everyone who uses this computer.</summary>
    public static readonly LocalStore Store = new(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "StreamSetu"));
    public static readonly ISecretStore Secrets = new CredentialManagerSecrets();
    public static readonly HostAllowList Allow = new();
    public static readonly ProfileManager Profiles = new(Store);
    public static readonly ReminderStore Reminders = new(Store);
    public static readonly RecordingStore Recordings = new(Store);
    public static LogoCache Logos = null!;
    public static LanService Lan = null!;
    /// <summary>The encrypted-DNS resolver when one is chosen; the player is given addresses found with it.</summary>
    public static IHostResolver? Resolver;

    public static SafeHttp Http = null!;
    public static LibraryLoader Loader = null!;
    public static AppSettings Settings = AppSettings.Load(Store);

    // The signed-in profile's own favourites, history, folders and collections.
    public static Profile Profile = null!;
    public static LocalStore User = null!;
    public static FolderPrefs Folders = null!;
    public static Collections Collections = null!;
    /// <summary>Home's shown-history and shuffle counter for the signed-in profile.</summary>
    public static SmartMixStore Mix = null!;
    public static readonly PlayQueue Queue = new();
    public static readonly SleepTimer Sleep = new(() => DateTimeOffset.UtcNow);

    public static Window MainWindow = null!;
    public static IntPtr MainHandle;
    public static IntPtr VideoHandle;
    public static MpvBackend? Mpv;
    public static PlaybackSession? Session;

    private static readonly Dictionary<string, LoadedLibrary> Loaded = new();
    private static readonly Dictionary<string, Guide> Guides = new();

    static AppServices() { ApplyNetwork(); SignIn(Profiles.Find(Settings.LastProfileId ?? "") ?? Profiles.All()[0]); }

    /// <summary>(Re)builds the downloader, with the chosen encrypted DNS if there is one. Called at start and whenever the DNS choice changes.</summary>
    public static void ApplyNetwork()
    {
        Http?.Dispose();
        Resolver = Settings.Resolver is { } provider ? new DohResolver(provider, new HttpClient { Timeout = TimeSpan.FromSeconds(10) }) : null;
        Http = new SafeHttp(Allow, UserAgent, resolver: Resolver);
        Loader = new LibraryLoader(new SafeTextFetcher(Http), Secrets);
        Logos = new LogoCache(new SafeBytesFetcher(Http), Path.Combine(Store.Folder, "logos"));
        if (Mpv is not null) Mpv.Pinner = PinnerFor(Resolver);
    }

    private static Func<string, CancellationToken, Task<PinnedAddress>>? PinnerFor(IHostResolver? resolver) => resolver is null ? null : (url, ct) => Pinning.PinAsync(url, resolver, Allow, ct);

    /// <summary>The address to give the player for a title of a connection (a Stalker portal hands out a fresh link each time).</summary>
    public static Task<string> PlayUrlAsync(Playlist playlist, string url) => Loader.ResolvePlayUrlAsync(playlist, url);

    /// <summary>The same, for a key like "playlistId|movie:9" (the play queue only remembers keys).</summary>
    public static Task<string> PlayUrlForKeyAsync(string key, string url)
    {
        var id = key.Split('|')[0];
        return Playlists().FirstOrDefault(p => p.Id == id) is { } p ? PlayUrlAsync(p, url) : Task.FromResult(url);
    }

    public static void SignIn(Profile profile)
    {
        Profile = profile; User = Profiles.StoreOf(profile.Id);
        Folders = new FolderPrefs(User); Collections = new Collections(User); Mix = new SmartMixStore(User);
        Queue.Clear();
        Settings = Settings with { LastProfileId = profile.Id }; Settings.Save(Store);
    }

    public static void SaveSettings(AppSettings settings)
    {
        var dnsChanged = settings.Dns != Settings.Dns;
        Settings = settings; settings.Save(Store);
        if (dnsChanged) ApplyNetwork();
    }

    /// <summary>A host that is in a connection may be on the home network; every other address on it is refused.</summary>
    public static void AllowHostOf(Playlist p)
    {
        if (p.Kind == PlaylistKind.LocalFolder) return;
        var address = p.Kind == PlaylistKind.M3u && !p.Address.StartsWith("http", StringComparison.OrdinalIgnoreCase) ? null : p.Address;
        if (address is not null && Uri.TryCreate(Xtream.NormalizeHost(address), UriKind.Absolute, out var u)) Allow.Add(u.Host);
    }

    public static void AllowSavedHosts() { foreach (var p in Store.Playlists()) AllowHostOf(p); }

    public static async Task<LoadedLibrary> LoadAsync(Playlist p, bool refresh = false)
    {
        if (!refresh && Loaded.TryGetValue(p.Id, out var cached)) return cached;
        AllowHostOf(p);
        var library = await Loader.LoadAsync(p);
        Loaded[p.Id] = library;
        return library;
    }

    public static void Forget(string playlistId) { Loaded.Remove(playlistId); Guides.Remove(playlistId); }

    /// <summary>The programme guide of a connection, loaded once and kept until the connection is refreshed. Null when the connection has no guide address.</summary>
    public static async Task<Guide?> GuideAsync(Playlist p, bool refresh = false)
    {
        if (!refresh && Guides.TryGetValue(p.Id, out var cached)) return cached;
        var password = p.Kind == PlaylistKind.Xtream ? Secrets.Get(p.SecretRef ?? LibraryLoader.SecretKey(p.Id)) : null;
        var address = GuideLoader.AddressFor(p, password, Settings);
        if (address is null) return null;
        if (Uri.TryCreate(address, UriKind.Absolute, out var u)) Allow.Add(u.Host);
        var xml = await Http.FetchTextAsync(address, GuideLoader.MaxGuideBytes);
        var guide = new Guide(await Task.Run(() => Xmltv.Parse(xml)));
        Guides[p.Id] = guide;
        return guide;
    }

    /// <summary>The video window and the player are made on first use, because they need the main window to exist.</summary>
    public static PlaybackSession EnsurePlayer()
    {
        if (Session is not null) return Session;
        VideoHandle = VideoWindow.Create(MainHandle);
        Mpv = new MpvBackend(VideoHandle) { Pinner = PinnerFor(Resolver) };
        Session = new PlaybackSession(Mpv);
        return Session;
    }

    /// <summary>The key that favourites, progress, watched marks and collections use for a title: the connection, then the title.</summary>
    public static string KeyOf(Playlist p, Item i) => p.Id + "|" + i.Id;

    // ---------- Home, folder rows and the privacy rules ----------

    private static readonly (Kind Kind, string Mode)[] Modes = { (Kind.Movie, "movie"), (Kind.Series, "series"), (Kind.Live, "live") };

    /// <summary>Every movie and series of every connection, as copies. Connections that cannot be loaded are left out; nothing is refreshed here, so this never starts a sync.</summary>
    public static async Task<List<Copy>> AllCopiesAsync()
    {
        var all = new List<Copy>();
        foreach (var p in Playlists())
        {
            try
            {
                var lib = (await LoadAsync(p)).Library;
                all.AddRange(lib.Movies.Select(i => new Copy(p.Id, i)));
                all.AddRange(lib.Series.Select(i => new Copy(p.Id, i)));
            }
            catch (Exception) { /* a connection that is down simply has nothing on Home */ }
        }
        return all;
    }

    /// <summary>Locked and hidden folders of this profile across all connections, by the name the connection lists. <paramref name="unlocked"/> are the folders opened with their PIN during this visit.</summary>
    public static PrivacyInput PrivacyNow(IReadOnlySet<string>? unlocked = null)
    {
        var locked = new Dictionary<Kind, IReadOnlySet<string>>(); var hidden = new Dictionary<Kind, IReadOnlySet<string>>(); var open = new Dictionary<Kind, IReadOnlySet<string>>();
        foreach (var (kind, mode) in Modes)
        {
            var l = new HashSet<string>(); var h = new HashSet<string>();
            foreach (var p in Playlists()) { l.UnionWith(Folders.LockedGroups(p.Id + "|" + mode)); h.UnionWith(Folders.HiddenGroups(p.Id + "|" + mode)); }
            locked[kind] = l; hidden[kind] = h; open[kind] = unlocked is null ? new HashSet<string>() : l.Where(unlocked.Contains).ToHashSet();
        }
        return new PrivacyInput(locked, hidden, open, false, Profile.Kids);
    }

    /// <summary>What the person has done with a title, for the ranking.</summary>
    public static Func<Copy, WatchInfo> WatchFn()
    {
        var watched = User.Watched(); var recent = User.RecentProgress().ToDictionary(kv => kv.Key, kv => kv.Value.At);
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        return c =>
        {
            var key = c.StoreKey;
            var isWatched = watched.Contains(key);
            int? ago = recent.TryGetValue(key, out var at) ? (int)Math.Max(0, (now - at) / 86_400_000) : null;
            return new WatchInfo(isWatched, isWatched, ago, ago is <= 7 ? 1 : 0, ago is <= 30 ? 1 : 0);
        };
    }

    public static IReadOnlyDictionary<string, int> SourceRank() =>
        PreferredSource.Ranking(Playlists().Select((p, i) => new SourceHealth(p.Id, true, "ok", null, i)));

    /// <summary>The weekly TMDB list, refreshed at most once a day, and only with the person's own key. Returns what the engine takes.</summary>
    public static async Task<TrendingInput> TrendingAsync()
    {
        var key = Secrets.Get("tmdb:key");
        var enabled = Settings.TmdbEnabled;
        try { Allow.Add("api.themoviedb.org"); await Tmdb.RefreshAsync(Store, new SafeTextFetcher(Http), key, enabled, DateTimeOffset.UtcNow); }
        catch (Exception) { /* offline: the cached list, or the library's own order */ }
        var cache = enabled && !string.IsNullOrWhiteSpace(key) ? Tmdb.Load(Store) : null;
        return new TrendingInput(enabled, !string.IsNullOrWhiteSpace(key), Tmdb.ForEngine(cache, DateTimeOffset.UtcNow));
    }

    private static IEnumerable<string> GroupsOf(Library lib, string mode)
        => (mode switch { "movie" => lib.Movies, "series" => lib.Series, _ => lib.Live }).Select(i => i.Group).Distinct();

    /// <summary>Locks a folder in every connection that lists a folder of the same name (spelled in capitals or not): a twin connection's copy of the folder is the same folder to the person. Nothing in a connection changes.</summary>
    public static void LockEverywhere(string mode, string group, string pin)
    {
        foreach (var p in Playlists())
            Folders.SetLockFamily(p.Id + "|" + mode, group, pin, Loaded.TryGetValue(p.Id, out var l) ? GroupsOf(l.Library, mode) : Enumerable.Empty<string>());
    }

    public static void HideEverywhere(string mode, string group)
    {
        foreach (var p in Playlists())
            Folders.HideFamily(p.Id + "|" + mode, group, true, Loaded.TryGetValue(p.Id, out var l) ? GroupsOf(l.Library, mode) : Enumerable.Empty<string>());
    }

    public static string DayKey() => DateTime.Now.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);

    public static HomeInputs BuildHomeInputs(List<Copy> copies, TrendingInput tmdb, IReadOnlySet<string>? unlocked = null)
        => new(copies, PrivacyNow(unlocked), DayKey(), Settings.PreferredLanguage, tmdb, WatchFn(), SourceRank());

    public static IReadOnlyList<Playlist> Playlists() => Store.Playlists();
}

/// <summary>What the player screen is asked to play.</summary>
internal sealed record PlayRequest(Playlist Playlist, string Key, string Title, string Url, bool Live, double StartAt, Item? Channel = null);
