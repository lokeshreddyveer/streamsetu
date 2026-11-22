using System.Globalization;

namespace StreamSetu.Core.SmartMix;

/// <summary>What the person has done with a title, for the ranking (counts are identity-level, so a title watched in another playlist counts too).</summary>
public sealed record WatchInfo(bool Watched = false, bool Completed = false, int? LastWatchedDaysAgo = null, int Plays7 = 0, int Plays30 = 0, bool Dismissed = false);

/// <summary>Turns the playlists' items into engine candidates. Restriction is decided here by the privacy rules (twin copies included) and again by the engine per identity group.</summary>
public static class SmartMixCandidates
{
    /// <param name="sourceRank">0 is the best playlist for choosing a copy (see <see cref="PreferredSource"/>).</param>
    public static List<Cand> Build(IReadOnlyCollection<Copy> copies, PrivacySnapshot recommend, DateTimeOffset dayStart, Func<Copy, WatchInfo> watch, IReadOnlyDictionary<string, int>? sourceRank = null)
    {
        var list = new List<Cand>(copies.Count);
        foreach (var c in copies)
        {
            var it = c.Item;
            if (it.Kind == Kind.Live) continue;
            var id = IdentityDerive.Derive(it.Title, it.Group, it.Year, it.Kind);
            var w = watch(c);
            list.Add(new Cand
            {
                Id = c.StoreKey,
                Kind = it.Kind == Kind.Series ? "series" : "movie",
                Key = id.Key,
                Year = id.Year,
                Added = it.Added is { } a ? Math.Max(0, (long)(dayStart - a).TotalDays) : null,
                Rating = it.Rating is { } r && r > 0 ? r.ToString("0.0", CultureInfo.InvariantCulture) : null,
                Q = id.QualityRank,
                Cam = id.IsCam,
                Lang = id.Language,
                Folder = id.FolderKey,
                Poster = !string.IsNullOrEmpty(it.Logo),
                Backdrop = false,
                Watched = w.Watched,
                Completed = w.Completed,
                LastWatched = w.LastWatchedDaysAgo,
                P7 = w.Plays7,
                P30 = w.Plays30,
                Dismissed = w.Dismissed,
                Restricted = !recommend.ItemOk(c),
                Src = sourceRank is not null && sourceRank.TryGetValue(c.PlaylistId, out var s) ? s : 0,
            });
        }
        return list;
    }
}
