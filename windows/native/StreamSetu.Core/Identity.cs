using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace StreamSetu.Core;

/// <summary>One title's identity, derived from what the playlist says about it. Nothing is stored on the playlist rows: it is a pure function of the title, its folder's name and its year.</summary>
public sealed record DerivedIdentity(string Key, int? Year, string? Language, int QualityRank, bool IsCam, string? FolderKey);

/// <summary>IdentityKey v1: the frozen matching rule behind "the same title" (year, quality words, language words, "and" and a leading article removed). Changing a word list is a new version.</summary>
public static class IdentityKey
{
    public const int Version = 1;
    private static readonly HashSet<string> Articles = new() { "the", "a", "an" };
    private static readonly HashSet<string> Noise = new()
    {
        "hd", "fhd", "uhd", "4k", "sd", "hdcam", "cam", "webrip", "web", "dl", "bluray", "dvdrip", "hevc", "x264", "x265", "h264", "h265", "dubbed", "dub", "multi", "sub", "subs", "eng", "season", "episode",
    };

    /// <summary>The words a title or folder uses for a language, with the name shown for it.</summary>
    public static readonly IReadOnlyDictionary<string, string> LanguageNames = BuildLanguages();

    private static Dictionary<string, string> BuildLanguages()
    {
        var d = new Dictionary<string, string>();
        foreach (var w in new[]
        {
            "english", "hindi", "tamil", "telugu", "kannada", "malayalam", "urdu", "punjabi", "bengali", "marathi", "gujarati", "arabic", "spanish", "french", "german", "korean", "japanese", "chinese",
            "turkish", "russian", "italian", "portuguese", "thai", "indonesian", "odia", "assamese", "nepali", "sinhala", "persian", "hebrew", "vietnamese", "tagalog", "malay", "pashto",
        }) d[w] = char.ToUpperInvariant(w[0]) + w[1..];
        d["bangla"] = "Bengali"; d["farsi"] = "Persian"; d["filipino"] = "Tagalog"; d["oriya"] = "Odia"; d["odiya"] = "Odia";
        return d;
    }

    /// <summary>Lower case, accents removed, every other character that is not a letter or digit a space; split into words. No culture is read.</summary>
    public static List<string> Words(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (var ch in s.Normalize(NormalizationForm.FormD))
        {
            var cat = CharUnicodeInfo.GetUnicodeCategory(ch);
            if (cat is UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.EnclosingMark) continue;
            sb.Append(char.IsLetterOrDigit(ch) ? char.ToLowerInvariant(ch) : ' ');
        }
        return sb.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
    }

    /// <summary>A folder's name compared across playlists: "ENGLISH | GENERAL" and "English | General" are one family.</summary>
    public static string Normalize(string s) => string.Join(' ', Words(s));

    private static bool IsYear(string w) => w.Length == 4 && w.All(char.IsDigit) && (w.StartsWith("19", StringComparison.Ordinal) || w.StartsWith("20", StringComparison.Ordinal));

    public static string Make(string title)
    {
        var all = Words(title);
        var w = all.Where(x => !IsYear(x) && !Noise.Contains(x) && !LanguageNames.ContainsKey(x) && x != "and").ToList();
        if (w.Count > 1 && Articles.Contains(w[0])) w.RemoveAt(0);
        // A title made only of such words ("HD", "English") keeps them rather than collapse to nothing.
        return w.Count == 0 ? string.Join(' ', all) : string.Join(' ', w);
    }
}

public static class IdentityDerive
{
    private static readonly Regex TagPattern = new(@"[\(\[]\s*([A-Za-z]+)\s*[\)\]]", RegexOptions.CultureInvariant);
    private static readonly Regex YearInTitle = new(@"(?<![0-9])((?:19|20)[0-9]{2})(?![0-9])", RegexOptions.CultureInvariant);
    private static readonly Regex CinemaCopy = new(@"\b(cam|hdcam|hd-cam|camrip|ts|hdts|telesync|tc|telecine)\b", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    private static readonly HashSet<string> SubtitleWords = new() { "subtitles", "subtitle", "subs", "sub", "subbed" };

    /// <summary>A "(Lang)" tag in the title, a dub named by the folder, the first language word of the folder that is not a subtitle language, then a language word in the title.</summary>
    public static string? Language(string title, string? folder)
    {
        foreach (Match m in TagPattern.Matches(title))
            if (IdentityKey.LanguageNames.TryGetValue(m.Groups[1].Value.ToLowerInvariant(), out var tagged)) return tagged;
        var f = folder is null ? new List<string>() : IdentityKey.Words(folder);
        for (var i = 0; i < f.Count; i++)
        {
            if (f[i] != "dubbed") continue;
            if (i > 0 && IdentityKey.LanguageNames.TryGetValue(f[i - 1], out var before)) return before;
            if (i + 2 < f.Count && f[i + 1] == "in" && IdentityKey.LanguageNames.TryGetValue(f[i + 2], out var after)) return after;
        }
        for (var i = 0; i < f.Count; i++)
        {
            if (!IdentityKey.LanguageNames.TryGetValue(f[i], out var name)) continue;
            if (i + 1 < f.Count && SubtitleWords.Contains(f[i + 1])) continue;
            return name;
        }
        foreach (var w in IdentityKey.Words(title)) if (IdentityKey.LanguageNames.TryGetValue(w, out var n)) return n;
        return null;
    }

    /// <summary>4K 5, FHD 4, HD 3, unmarked 2, SD 1, a cinema recording 0 (one vocabulary for ranking copies).</summary>
    public static (int Rank, bool IsCam) Quality(string title, string? folder)
    {
        var text = folder is null ? title : title + " " + folder;
        if (CinemaCopy.IsMatch(text)) return (0, true);
        return Tags.Of(title).Quality switch { StreamSetu.Core.Quality.Uhd4K => (5, false), StreamSetu.Core.Quality.Hd1080 => (4, false), StreamSetu.Core.Quality.Hd720 => (3, false), StreamSetu.Core.Quality.Sd => (1, false), _ => (2, false) };
    }

    public static int? Year(int? declared, string title)
    {
        if (declared is > 0) return declared;
        var m = YearInTitle.Match(title);
        return m.Success ? int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture) : null;
    }

    public static DerivedIdentity Derive(string title, string? categoryName, int? year, Kind kind)
    {
        var q = Quality(title, categoryName);
        var folderWords = categoryName is null ? "" : IdentityKey.Normalize(categoryName);
        return new DerivedIdentity(IdentityKey.Make(title), Year(year, title), Language(title, categoryName), q.Rank, q.IsCam, folderWords.Length == 0 ? null : $"{kind.ToString().ToLowerInvariant()}|{folderWords}");
    }

    /// <summary>FNV-1a 64 of what identity was derived from: when it is the same, the row is not derived again on a sync.</summary>
    public static long InputHash(string title, string? categoryName, int? year)
    {
        ulong h = 0xcbf29ce484222325UL;
        foreach (var b in Encoding.UTF8.GetBytes($"{title}|{categoryName ?? ""}|{year?.ToString(CultureInfo.InvariantCulture) ?? ""}")) { h ^= b; unchecked { h *= 0x100000001b3UL; } }
        return unchecked((long)h);
    }
}

/// <summary>One copy of a title, as the identity layer sees it.</summary>
public sealed record IdentityMember(string ItemId, string SourceId, string? Language, int QualityRank, bool IsCam, int? Year, double AddedAt);

/// <summary>A playlist's standing for choosing between copies, from what the app already knows (no network).</summary>
public sealed record SourceHealth(string Id, bool Enabled, string SyncStatus, DateTimeOffset? LastSync, int SortOrder);

public static class PreferredSource
{
    public static readonly TimeSpan StaleAfter = TimeSpan.FromDays(14);

    /// <summary>Playlists best first, as a rank (0 is best): enabled ones; then ones not failed or 14-days-stale (unless the only one); then the person's own choice; then the playlist order; then the id.</summary>
    public static Dictionary<string, int> Ranking(IEnumerable<SourceHealth> sources, string? userPreferred = null, DateTimeOffset? now = null)
    {
        var list = sources.ToList(); var at = now ?? DateTimeOffset.UtcNow;
        var enabledCount = list.Count(s => s.Enabled);
        bool Healthy(SourceHealth s)
        {
            if (s.SyncStatus == "failed") return false;
            if (enabledCount <= 1) return true;
            return s.LastSync is not { } last || at - last <= StaleAfter;
        }
        list.Sort((a, b) =>
        {
            if (a.Enabled != b.Enabled) return a.Enabled ? -1 : 1;
            var ha = Healthy(a); var hb = Healthy(b);
            if (ha != hb) return ha ? -1 : 1;
            var pa = a.Id == userPreferred; var pb = b.Id == userPreferred;
            if (pa != pb) return pa ? -1 : 1;
            if (a.SortOrder != b.SortOrder) return a.SortOrder.CompareTo(b.SortOrder);
            return SmartMix.Utf8Order.Compare(a.Id.ToLowerInvariant(), b.Id.ToLowerInvariant());
        });
        return list.Select((s, i) => (s.Id, i)).ToDictionary(t => t.Id, t => t.i);
    }

}

/// <summary>Which copy of a title a card shows. Deterministic: the same copies always give the same order. The other copies stay available as alternatives (never deleted or merged).</summary>
public static class CanonicalPick
{
    public sealed record Context(string? PreferredLanguage = null, IReadOnlyDictionary<string, int>? SourceRank = null);

    /// <summary>Best first: (1) the preferred audio language, (2) the better picture (a cinema recording last), (3) the preferred playlist, (4) the newer addition, (5) the item id, bytewise.</summary>
    public static List<IdentityMember> Ordered(IEnumerable<IdentityMember> members, Context context)
    {
        var want = context.PreferredLanguage?.ToLowerInvariant();
        int Lang(IdentityMember m) => want is not null && m.Language?.ToLowerInvariant() == want ? 0 : 1;
        int Src(IdentityMember m) => context.SourceRank is not null && context.SourceRank.TryGetValue(m.SourceId, out var r) ? r : int.MaxValue;
        var list = members.ToList();
        list.Sort((a, b) =>
        {
            if (Lang(a) != Lang(b)) return Lang(a).CompareTo(Lang(b));
            if (a.QualityRank != b.QualityRank) return b.QualityRank.CompareTo(a.QualityRank);
            if (Src(a) != Src(b)) return Src(a).CompareTo(Src(b));
            if (a.AddedAt != b.AddedAt) return b.AddedAt.CompareTo(a.AddedAt);
            return SmartMix.Utf8Order.Compare(a.ItemId, b.ItemId);
        });
        return list;
    }

    public static IdentityMember? Pick(IEnumerable<IdentityMember> members, Context context) => Ordered(members, context).FirstOrDefault();

    /// <summary>The copies other than the pick: kept so "other versions" can still offer them.</summary>
    public static List<IdentityMember> Alternatives(IEnumerable<IdentityMember> members, Context context) => Ordered(members, context).Skip(1).ToList();

    /// <summary>The setting ("Telugu", "telugu") as the English language name used by identity, or null.</summary>
    public static string? LanguageName(string setting)
    {
        var s = setting.Trim();
        return s.Length > 0 && IdentityKey.LanguageNames.TryGetValue(s.ToLowerInvariant(), out var n) ? n : null;
    }
}
