namespace StreamSetu.Core;

/// <summary>Choices that belong to the computer, not to a profile. Secrets (the OpenSubtitles key and password) are not here: they are in Credential Manager.</summary>
public sealed record AppSettings
{
    /// <summary>"" for the system's DNS, a preset name (Cloudflare, Google, Quad9), or "https://…" for a server of the person's own.</summary>
    public string Dns { get; init; } = "";
    public string SubtitleLanguage { get; init; } = "en";
    public bool AutoSubtitles { get; init; }
    public string? OpenSubtitlesUser { get; init; }
    /// <summary>The XMLTV address for connections that do not give one themselves, by connection id.</summary>
    public Dictionary<string, string> GuideUrls { get; init; } = new();
    public List<string> AlertWords { get; init; } = new();
    public string? LastProfileId { get; init; }
    /// <summary>Whether sync on this network is on.</summary>
    public bool LanSync { get; init; }

    public static AppSettings Load(LocalStore store) => store.Load("Settings", new AppSettings());
    public void Save(LocalStore store) => store.Save("Settings", this);

    /// <summary>The encrypted-DNS server chosen, or null for the system's DNS (also when the choice is not a valid https address).</summary>
    public DnsProvider? Resolver => Dns.Length == 0 ? null : DnsProvider.Presets.FirstOrDefault(p => string.Equals(p.Name, Dns, StringComparison.OrdinalIgnoreCase)) ?? DnsProvider.Custom(Dns);
}

/// <summary>The programme guide for a connection.</summary>
public static class GuideLoader
{
    public const long MaxGuideBytes = 300L * 1024 * 1024;

    /// <summary>Xtream panels publish theirs at /xmltv.php; any other connection needs an address given in Settings.</summary>
    public static string? AddressFor(Playlist playlist, string? password, AppSettings settings)
    {
        if (playlist.Kind == PlaylistKind.Xtream && password is not null)
            return $"{Xtream.NormalizeHost(playlist.Address)}/xmltv.php?username={Xtream.EncodeComponent(playlist.Username ?? "")}&password={Xtream.EncodeComponent(password)}";
        return settings.GuideUrls.TryGetValue(playlist.Id, out var url) && Uri.TryCreate(url, UriKind.Absolute, out var u) && (u.Scheme == Uri.UriSchemeHttp || u.Scheme == Uri.UriSchemeHttps) ? url : null;
    }
}
