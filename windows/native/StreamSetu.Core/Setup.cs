using System.Text.RegularExpressions;

namespace StreamSetu.Core;

/// <summary>What a pasted link most likely is, so the setup screen can open the right form with the fields filled in.</summary>
public sealed record PasteGuess(PlaylistKind Kind, string Address, string? User = null, string? Secret = null);

public static class SetupPaste
{
    private static readonly Regex StreamFile = new(@"\.(ts|mp4|mkv|avi|mov|flv|mpd|webm|aac|mp3)(\?|$)", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    /// <summary>Null when the text is not a link or file path the app could use.</summary>
    public static PasteGuess? Detect(string? text)
    {
        var t = (text ?? "").Trim().Trim('"');
        if (t.Length == 0) return null;
        if (Regex.IsMatch(t, @"^[A-Za-z]:\\") || t.StartsWith(@"\\", StringComparison.Ordinal))
            return t.EndsWith(".m3u", StringComparison.OrdinalIgnoreCase) || t.EndsWith(".m3u8", StringComparison.OrdinalIgnoreCase) ? new PasteGuess(PlaylistKind.M3u, t) : null;
        if (t.StartsWith("rtmp://", StringComparison.OrdinalIgnoreCase) || t.StartsWith("rtsp://", StringComparison.OrdinalIgnoreCase) || t.StartsWith("udp://", StringComparison.OrdinalIgnoreCase)) return new PasteGuess(PlaylistKind.SingleStream, t);
        if (!Uri.TryCreate(t, UriKind.Absolute, out var u) || (u.Scheme != Uri.UriSchemeHttp && u.Scheme != Uri.UriSchemeHttps)) return null;
        var query = System.Web.HttpUtility.ParseQueryString(u.Query);
        var path = u.AbsolutePath;
        var origin = u.GetLeftPart(UriPartial.Authority);
        if ((path.EndsWith("/get.php", StringComparison.OrdinalIgnoreCase) || path.EndsWith("/player_api.php", StringComparison.OrdinalIgnoreCase) || path.EndsWith("/xmltv.php", StringComparison.OrdinalIgnoreCase))
            && query["username"] is { Length: > 0 } user && query["password"] is { Length: > 0 } pass)
            return new PasteGuess(PlaylistKind.Xtream, origin, user, pass);
        if (path.Contains("/portal.php", StringComparison.OrdinalIgnoreCase) || path.EndsWith("/c/", StringComparison.OrdinalIgnoreCase) || path.EndsWith("/c", StringComparison.OrdinalIgnoreCase)) return new PasteGuess(PlaylistKind.Stalker, t);
        if (u.Port == 32400 || query["X-Plex-Token"] is { Length: > 0 }) return new PasteGuess(PlaylistKind.Plex, origin, null, query["X-Plex-Token"]);
        if (u.Port == 8096 && !path.Contains(".m3u", StringComparison.OrdinalIgnoreCase)) return new PasteGuess(PlaylistKind.Jellyfin, origin);
        if (u.Port == 9981) return new PasteGuess(PlaylistKind.TvHeadend, origin);
        if (path.EndsWith("/lineup.json", StringComparison.OrdinalIgnoreCase) || path.EndsWith("/discover.json", StringComparison.OrdinalIgnoreCase)) return new PasteGuess(PlaylistKind.HdHomeRun, origin);
        if (path.EndsWith(".m3u", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".m3u8", StringComparison.OrdinalIgnoreCase) || query["type"] == "m3u" || query["type"] == "m3u_plus" || path.EndsWith("/get.php", StringComparison.OrdinalIgnoreCase))
            return new PasteGuess(PlaylistKind.M3u, t);
        if (StreamFile.IsMatch(t)) return new PasteGuess(PlaylistKind.SingleStream, t);
        return new PasteGuess(PlaylistKind.M3u, t);                      // an unknown web address is most often a playlist link; the person can change the type
    }
}

/// <summary>A form that was started and not finished. Kept so "Continue previous setup" can bring it back. Passwords, keys and tokens are never kept in it.</summary>
public sealed record SetupDraft(PlaylistKind Kind, string Name, string Address, string? User)
{
    public bool IsEmpty => string.IsNullOrWhiteSpace(Name) && string.IsNullOrWhiteSpace(Address) && string.IsNullOrWhiteSpace(User);
}

public sealed class SetupDrafts(LocalStore store)
{
    private const string Name = "SetupDraft";
    public SetupDraft? Load() => store.Load<SetupDraft?>(Name, null) is { IsEmpty: false } d ? d : null;
    public void Save(SetupDraft draft) { if (draft.IsEmpty) Clear(); else store.Save<SetupDraft?>(Name, draft); }
    public void Clear() { if (store.Load<SetupDraft?>(Name, null) is not null) store.Save<SetupDraft?>(Name, null); }
}
