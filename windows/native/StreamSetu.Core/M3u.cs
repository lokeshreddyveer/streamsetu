using System.Text.RegularExpressions;

namespace StreamSetu.Core;

/// <summary>Reads M3U and M3U8 playlists.</summary>
public static class M3u
{
    // ECMAScript mode keeps \d, \s and \b to plain ASCII, the same as the web version these rules came from.
    private const RegexOptions Js = RegexOptions.ECMAScript | RegexOptions.IgnoreCase;
    private static readonly Regex Attribute = new("([A-Za-z0-9_-]+)=\"([^\"]*)\"", RegexOptions.ECMAScript);
    private static readonly Regex EpisodePattern = new(@"^(.*?)[\s._-]+S(\d{1,2})[\s._-]*E(\d{1,3})\b", Js);
    private static readonly Regex SeriesGroup = new(@"\b(series|serial|tv shows?|shows)\b", Js);
    private static readonly Regex MovieGroup = new(@"\b(movies?|films?|vod|cinema)\b", Js);
    private static readonly Regex MovieFile = new(@"\.(mp4|mkv|avi|mov|m4v)(\?|$)", Js);
    private static readonly Regex Scheme = new(@"^[a-z][a-z0-9+.-]*://", Js);
    private static readonly Regex Extension = new(@"\.([a-z0-9]{2,4})(\?|$)", Js);

    /// <summary>key="value" pairs of an #EXTINF line. Values may hold commas, so they are read before the title.</summary>
    private static Dictionary<string, string> Attributes(string line)
    {
        var map = new Dictionary<string, string>();
        foreach (Match m in Attribute.Matches(line)) map[m.Groups[1].Value.ToLowerInvariant()] = m.Groups[2].Value;
        return map;
    }

    /// <summary>The title after the last comma that is not inside quotes.</summary>
    private static string TitleOf(string line)
    {
        bool inQuote = false; int cut = -1;
        for (int i = 0; i < line.Length; i++)
        {
            char c = line[i];
            if (c == '"') inQuote = !inQuote;
            else if (c == ',' && !inQuote) cut = i;
        }
        return cut >= 0 ? line[(cut + 1)..].Trim() : "";
    }

    /// <summary>What kind of thing an entry is: Xtream-style paths say so, otherwise a group name or the numbering does.</summary>
    public static Kind Classify(string url, string group, string title)
    {
        var path = url.ToLowerInvariant();
        if (path.Contains("/series/")) return Kind.Series;
        if (path.Contains("/movie/")) return Kind.Movie;
        if (path.Contains("/live/")) return Kind.Live;
        var g = group.ToLowerInvariant();
        if (SeriesGroup.IsMatch(g) || EpisodePattern.IsMatch(title)) return Kind.Series;
        if (MovieGroup.IsMatch(g) || MovieFile.IsMatch(path)) return Kind.Movie;
        return Kind.Live;
    }

    /// <summary>Entries that are not playable (no address) are dropped, and repeated addresses stay once.</summary>
    public static List<Item> Parse(string text)
    {
        var items = new List<Item>();
        var seen = new HashSet<string>();
        (string Title, Dictionary<string, string> Attrs)? pending = null;
        int n = 0;
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0) continue;
            if (line.StartsWith("#EXTINF", StringComparison.Ordinal)) { pending = (TitleOf(line), Attributes(line)); continue; }
            if (line.StartsWith('#')) continue;
            if (!Scheme.IsMatch(line) || pending is null) { pending = null; continue; }
            if (!seen.Add(line)) { pending = null; continue; }
            var (pendingTitle, a) = pending.Value;
            string Get(string key) => a.TryGetValue(key, out var v) ? v : "";
            var title = pendingTitle.Length > 0 ? pendingTitle : Get("tvg-name").Length > 0 ? Get("tvg-name") : line;
            var group = Get("group-title");
            var kind = Classify(line, group, title);
            var item = new Item
            {
                Id = $"m3u:{n++}", Kind = kind, Title = title, Url = line,
                Group = group.Length > 0 ? group : kind switch { Kind.Live => "Channels", Kind.Movie => "Movies", _ => "Series" },
                Logo = Get("tvg-logo") is { Length: > 0 } logo ? logo : null,
                EpgId = Get("tvg-id") is { Length: > 0 } epg ? epg : null,
            };
            if (kind == Kind.Series && EpisodePattern.Match(title) is { Success: true } ep)
                item = item with { Title = ep.Groups[1].Value.Trim(), Season = int.Parse(ep.Groups[2].Value), Episode = int.Parse(ep.Groups[3].Value) };
            if (Extension.Match(line) is { Success: true } ext) item = item with { Ext = ext.Groups[1].Value.ToLowerInvariant() };
            items.Add(item);
            pending = null;
        }
        return items;
    }

    /// <summary>Splits parsed entries into the three lists. Episodes of one show become a single series entry that remembers its episodes.</summary>
    public static Library ToLibrary(IEnumerable<Item> items)
    {
        var library = new Library();
        foreach (var it in items)
        {
            if (it.Kind == Kind.Live) library.Live.Add(it);
            else if (it.Kind == Kind.Movie) library.Movies.Add(it);
            else
            {
                var key = it.Title.ToLowerInvariant();
                if (library.Episodes.TryGetValue(key, out var list)) list.Add(it);
                else
                {
                    library.Episodes[key] = new List<Item> { it };
                    library.Series.Add(new Item { Id = $"show:{key}", Kind = Kind.Series, Title = it.Title, Group = it.Group, Logo = it.Logo, SeriesId = key });
                }
            }
        }
        foreach (var key in library.Episodes.Keys.ToList())
            library.Episodes[key] = library.Episodes[key].OrderBy(e => e.Season ?? 0).ThenBy(e => e.Episode ?? 0).ToList();
        return library;
    }
}
