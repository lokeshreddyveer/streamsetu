using System.Globalization;
using System.Xml;

namespace StreamSetu.Core;

public sealed record Programme(string ChannelId, DateTimeOffset Start, DateTimeOffset Stop, string Title, string? Description);

/// <summary>Reads an XMLTV guide.</summary>
public static class Xmltv
{
    /// <summary>"20261107183000 +0100", "20261107183000" (taken as UTC) or "202611071830". Null when it is not a time.</summary>
    public static DateTimeOffset? ParseTime(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var parts = text.Trim().Split(' ', 2, StringSplitOptions.RemoveEmptyEntries);
        var stamp = parts[0];
        if (stamp.Length < 12 || !stamp.All(char.IsAsciiDigit)) return null;
        if (stamp.Length > 14) stamp = stamp[..14];
        stamp = stamp.PadRight(14, '0');
        if (!DateTime.TryParseExact(stamp, "yyyyMMddHHmmss", CultureInfo.InvariantCulture, DateTimeStyles.None, out var local)) return null;
        var offset = TimeSpan.Zero;
        if (parts.Length == 2)
        {
            var z = parts[1];
            if (z.Length == 5 && (z[0] == '+' || z[0] == '-') && int.TryParse(z[1..3], out var h) && int.TryParse(z[3..], out var m) && h <= 14 && m < 60)
                offset = new TimeSpan(h, m, 0) * (z[0] == '-' ? -1 : 1);
        }
        return new DateTimeOffset(DateTime.SpecifyKind(local, DateTimeKind.Unspecified), offset);
    }

    /// <summary>Programmes with a channel, a start, a stop after the start, and a title. A guide file is outside data: DTDs are refused (no external files, no entity bombs) and the size is capped.</summary>
    public static List<Programme> Parse(string xml, int maxProgrammes = 2_000_000)
    {
        var list = new List<Programme>();
        var settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, IgnoreComments = true, MaxCharactersFromEntities = 0 };
        try
        {
            using var reader = XmlReader.Create(new StringReader(xml), settings);
            reader.MoveToContent();
            while (!reader.EOF && list.Count < maxProgrammes)
            {
                if (reader.NodeType != XmlNodeType.Element || reader.Name != "programme") { reader.Read(); continue; }
                var el = (System.Xml.Linq.XElement)System.Xml.Linq.XNode.ReadFrom(reader);          // reads one programme and moves the reader past it
                var channel = (string?)el.Attribute("channel");
                var start = ParseTime((string?)el.Attribute("start")); var stop = ParseTime((string?)el.Attribute("stop"));
                var title = el.Element("title")?.Value.Trim(); var desc = el.Element("desc")?.Value.Trim();
                if (string.IsNullOrEmpty(channel) || start is null || stop is null || stop <= start || string.IsNullOrEmpty(title)) continue;
                list.Add(new Programme(channel, start.Value, stop.Value, title, string.IsNullOrEmpty(desc) ? null : desc));
            }
        }
        catch (XmlException e) { throw new InvalidOperationException("The guide file could not be read: " + e.Message); }
        return list;
    }
}

/// <summary>What is on, by channel and time.</summary>
public sealed class Guide
{
    private readonly Dictionary<string, List<Programme>> _byChannel = new(StringComparer.OrdinalIgnoreCase);

    public Guide(IEnumerable<Programme> programmes)
    {
        foreach (var p in programmes) { if (!_byChannel.TryGetValue(p.ChannelId, out var l)) _byChannel[p.ChannelId] = l = new(); l.Add(p); }
        foreach (var l in _byChannel.Values) l.Sort((a, b) => a.Start.CompareTo(b.Start));
    }

    public int ChannelCount => _byChannel.Count;

    public Programme? Now(string? channelId, DateTimeOffset at)
        => channelId is not null && _byChannel.TryGetValue(channelId, out var l) ? l.FirstOrDefault(p => p.Start <= at && at < p.Stop) : null;

    public Programme? Next(string? channelId, DateTimeOffset at)
        => channelId is not null && _byChannel.TryGetValue(channelId, out var l) ? l.FirstOrDefault(p => p.Start > at) : null;

    public List<Programme> Between(string? channelId, DateTimeOffset from, DateTimeOffset to)
        => channelId is not null && _byChannel.TryGetValue(channelId, out var l) ? l.Where(p => p.Stop > from && p.Start < to).ToList() : new();

    /// <summary>Programmes that began in the last <paramref name="days"/> days and have finished: what catch-up can offer.</summary>
    public List<Programme> Past(string? channelId, DateTimeOffset at, int days)
        => channelId is not null && _byChannel.TryGetValue(channelId, out var l) ? l.Where(p => p.Stop <= at && p.Start >= at.AddDays(-days)).Reverse().ToList() : new();

    /// <summary>Programmes (from now on) whose title or description holds a word the person asked to be told about.</summary>
    public List<Programme> Alerts(IEnumerable<string> words, DateTimeOffset from, DateTimeOffset to)
    {
        var w = words.Select(x => x.Trim()).Where(x => x.Length > 1).ToList();
        if (w.Count == 0) return new();
        return _byChannel.Values.SelectMany(l => l).Where(p => p.Start >= from && p.Start < to && w.Any(x => p.Title.Contains(x, StringComparison.CurrentCultureIgnoreCase) || (p.Description?.Contains(x, StringComparison.CurrentCultureIgnoreCase) ?? false)))
            .OrderBy(p => p.Start).ToList();
    }
}
