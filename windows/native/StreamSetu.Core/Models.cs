namespace StreamSetu.Core;

public enum PlaylistKind { Xtream, M3u, HdHomeRun, TvHeadend, Enigma2, Jellyfin, Emby, Plex, WebDav, LocalFolder, Stalker }

/// <summary>A playlist the person added. The password never lives here: it is kept in Windows Credential Manager under <see cref="SecretRef"/>.</summary>
public sealed record Playlist(string Id, string Name, PlaylistKind Kind, string Address, string? Username = null, string? SecretRef = null);

public enum Kind { Live, Movie, Series }

public sealed record Item
{
    public required string Id { get; init; }
    public required Kind Kind { get; init; }
    public required string Title { get; init; }
    public required string Group { get; init; }
    public string? Logo { get; init; }
    /// <summary>For live and movies, the address to play. Series are opened to list their episodes first.</summary>
    public string? Url { get; init; }
    /// <summary>The guide id (tvg-id) of a channel.</summary>
    public string? EpgId { get; init; }
    public int? Year { get; init; }
    public double? Rating { get; init; }
    public string? Plot { get; init; }
    /// <summary>Xtream series id, used to load the episodes.</summary>
    public string? SeriesId { get; init; }
    public int? Season { get; init; }
    public int? Episode { get; init; }
    public string? Ext { get; init; }
    /// <summary>When the provider added it, if it says.</summary>
    public DateTimeOffset? Added { get; init; }
}

public sealed record Episode(string Id, string Title, int Season, int Number, string Url, string? Ext);

public sealed class Library
{
    public List<Item> Live { get; } = new();
    public List<Item> Movies { get; } = new();
    public List<Item> Series { get; } = new();
    /// <summary>The episodes of each show found in an M3U list, keyed by the lower-case show title.</summary>
    public Dictionary<string, List<Item>> Episodes { get; } = new();
}
