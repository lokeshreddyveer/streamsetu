using System.Text.RegularExpressions;

namespace StreamSetu.Core;

/// <summary>How a folder is named on screen: acronyms in capitals, the count dimmed after the name in brackets.</summary>
public static class FolderNaming
{
    private static readonly HashSet<string> Acronyms = new(StringComparer.OrdinalIgnoreCase) { "FHD", "HD", "UHD", "4K", "SD", "HDR", "HDR10", "HEVC", "DV", "TV", "VOD", "UK", "US", "USA" };
    private static readonly Regex Word = new(@"[\p{L}\p{N}]+", RegexOptions.CultureInvariant);

    /// <summary>"english | 4k" -> "english · 4K". The playlist's own capitals are kept, only the acronyms are fixed and the bar becomes a dot.</summary>
    public static string Pretty(string name)
    {
        var t = Word.Replace(name.Trim(), m => Acronyms.Contains(m.Value) ? m.Value.ToUpperInvariant() : m.Value);
        return Regex.Replace(t, @"\s*[|/]\s*", " · ");
    }

    /// <summary>The count as it follows the name: "(1,058)". A locked folder has none.</summary>
    public static string CountText(int? count) => count is { } c ? "(" + c.ToString("N0", System.Globalization.CultureInfo.InvariantCulture) + ")" : "";

    /// <summary>"year · genre" under a tile, or nothing. Never the folder's name.</summary>
    public static string TileLine(int? year, string? genre)
    {
        var parts = new List<string>();
        if (year is > 0) parts.Add(year.Value.ToString(System.Globalization.CultureInfo.InvariantCulture));
        if (!string.IsNullOrWhiteSpace(genre)) parts.Add(genre!.Trim());
        return string.Join(" · ", parts);
    }
}
