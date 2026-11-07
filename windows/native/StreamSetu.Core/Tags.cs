using System.Text.RegularExpressions;

namespace StreamSetu.Core;

public enum Quality { Unknown = 0, Sd = 1, Hd720 = 2, Hd1080 = 3, Uhd4K = 4 }

public sealed record TitleTags(string? Language, Quality Quality, bool Hdr, bool DolbyVision, bool Atmos, bool Surround51, bool Cinema);

/// <summary>What a title says about itself: language prefix ("EN | ", "[FR]"), picture quality, sound, and whether it is a cinema recording.</summary>
public static class Tags
{
    private const RegexOptions O = RegexOptions.ECMAScript | RegexOptions.IgnoreCase;
    private static readonly Dictionary<string, string> Languages = new(StringComparer.OrdinalIgnoreCase)
    {
        ["en"] = "English", ["uk"] = "English", ["us"] = "English", ["fr"] = "French", ["de"] = "German", ["es"] = "Spanish", ["it"] = "Italian", ["pt"] = "Portuguese", ["nl"] = "Dutch",
        ["tr"] = "Turkish", ["ar"] = "Arabic", ["hi"] = "Hindi", ["te"] = "Telugu", ["ta"] = "Tamil", ["ml"] = "Malayalam", ["kn"] = "Kannada", ["bn"] = "Bengali", ["pa"] = "Punjabi",
        ["mr"] = "Marathi", ["gu"] = "Gujarati", ["ur"] = "Urdu", ["pl"] = "Polish", ["ru"] = "Russian", ["sv"] = "Swedish", ["gr"] = "Greek", ["ro"] = "Romanian", ["fa"] = "Persian",
    };
    private static readonly Regex Prefix = new(@"^\s*(?:\[([A-Za-z]{2})\]|\|([A-Za-z]{2})\||\(([A-Za-z]{2})\)|([A-Za-z]{2})\s*[:|\-]+\s+)", O);
    private static readonly Regex Uhd = new(@"\b(4k|uhd|2160p)\b", O), Fhd = new(@"\b(fhd|1080[pi])\b", O), Hd = new(@"\b(hd|720p)\b", O), Sd = new(@"\b(sd|480p|576p)\b", O);
    private static readonly Regex HdrTag = new(@"\bhdr(10\+?)?\b", O), DvTag = new(@"\b(dolby[\s._-]?vision|dv)\b", O), AtmosTag = new(@"\batmos\b", O), Ch51 = new(@"\b5[.\s]1\b", O);
    private static readonly Regex CinemaTag = new(@"\b(cam|camrip|hdcam|ts|hdts|telesync|tc|telecine|scr|screener)\b", O);
    private static readonly Regex NoiseTokens = new(@"\b(4k|uhd|2160p|fhd|1080[pi]|hd|720p|sd|480p|576p|hdr(10\+?)?|dolby[\s._-]?vision|dv|atmos|5[.\s]1|hevc|h\.?26[45]|x26[45]|cam|camrip|hdcam|ts|hdts|telesync|webrip|web-dl|bluray|brrip|dvdrip|multi|dual)\b", O);

    public static TitleTags Of(string title)
    {
        string? language = null;
        if (Prefix.Match(title) is { Success: true } m)
        {
            var code = new[] { 1, 2, 3, 4 }.Select(i => m.Groups[i].Value).First(v => v.Length > 0);
            if (Languages.TryGetValue(code, out var name)) language = name;
        }
        var quality = Uhd.IsMatch(title) ? Quality.Uhd4K : Fhd.IsMatch(title) ? Quality.Hd1080 : Hd.IsMatch(title) ? Quality.Hd720 : Sd.IsMatch(title) ? Quality.Sd : Quality.Unknown;
        return new TitleTags(language, quality, HdrTag.IsMatch(title), DvTag.IsMatch(title), AtmosTag.IsMatch(title), Ch51.IsMatch(title), CinemaTag.IsMatch(title));
    }

    /// <summary>A name that is the same for the same thing under different decorations: "EN | BBC One HD" and "UK: BBC One FHD" both become "bbc one".</summary>
    public static string Normalize(string title)
    {
        var t = Prefix.Replace(title, "");
        t = NoiseTokens.Replace(t, " ");
        t = Regex.Replace(t.ToLowerInvariant(), @"[^\p{L}\p{N}]+", " ");
        return Regex.Replace(t, @"\s+", " ").Trim();
    }
}

/// <summary>Choosing among copies of the same title.</summary>
public static class Versions
{
    /// <summary>Highest first: 4K, then 1080p, then 720p, then the rest, and a cinema recording never first.</summary>
    public static int Rank(string title)
    {
        var t = Tags.Of(title);
        return (t.Cinema ? -100 : 0) + (int)t.Quality * 10 + (t.Hdr || t.DolbyVision ? 1 : 0);
    }

    /// <summary>The copies of the same movie as <paramref name="movie"/> (same name and year), best first. The movie itself is always included.</summary>
    public static List<Item> Copies(Item movie, IEnumerable<Item> movies)
    {
        var key = Tags.Normalize(movie.Title);
        return movies.Where(m => m.Id == movie.Id || (Tags.Normalize(m.Title) == key && m.Year == movie.Year)).OrderByDescending(m => Rank(m.Title)).ToList();
    }
}

/// <summary>When a live channel stops working, the same channel in the person's other connections.</summary>
public static class Failover
{
    public sealed record Alternative(Playlist Playlist, Item Channel);

    public static List<Alternative> Alternatives(Playlist current, Item channel, IEnumerable<(Playlist Playlist, IEnumerable<Item> Live)> others)
    {
        var key = Tags.Normalize(channel.Title);
        if (key.Length == 0) return new();
        return others.Where(o => o.Playlist.Id != current.Id)
            .SelectMany(o => o.Live.Where(c => Tags.Normalize(c.Title) == key && c.Url is not null).OrderByDescending(c => Versions.Rank(c.Title)).Take(1).Select(c => new Alternative(o.Playlist, c)))
            .ToList();
    }
}
