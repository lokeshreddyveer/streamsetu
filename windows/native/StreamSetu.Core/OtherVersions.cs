namespace StreamSetu.Core;

/// <summary>"Other languages and versions": the other copies of a title (another language, quality or playlist), best first. Nothing is merged or hidden in the playlists; copies in locked, hidden or adult-blocked folders are never offered.</summary>
public static class OtherVersions
{
    public sealed record Version(Copy Copy, string? Language, int QualityRank, bool IsCam);

    public static string QualityLabel(int rank) => rank switch { 5 => "4K", 4 => "FHD", 3 => "HD", 1 => "SD", 0 => "CAM", _ => "" };

    public static List<Version> For(PrivacySnapshot visible, Copy of, IEnumerable<Copy> all, CanonicalPick.Context context)
    {
        var mine = IdentityDerive.Derive(of.Item.Title, of.Item.Group, of.Item.Year, of.Item.Kind);
        var found = new List<(Version V, IdentityMember M)>();
        foreach (var c in all)
        {
            if (c.Item.Kind != of.Item.Kind || c.Key == of.Key || !visible.ItemOk(c)) continue;
            var d = IdentityDerive.Derive(c.Item.Title, c.Item.Group, c.Item.Year, c.Item.Kind);
            if (d.Key != mine.Key) continue;
            if (d.Year is { } y && mine.Year is { } my && Math.Abs(y - my) > 1) continue;
            found.Add((new Version(c, d.Language, d.QualityRank, d.IsCam), new IdentityMember(c.Key, c.PlaylistId, d.Language, d.QualityRank, d.IsCam, d.Year, c.Item.Added?.ToUnixTimeSeconds() ?? 0)));
        }
        var order = CanonicalPick.Ordered(found.Select(f => f.M), context).Select(m => m.ItemId).ToList();
        return found.OrderBy(f => order.IndexOf(f.M.ItemId)).Select(f => f.V).ToList();
    }
}
