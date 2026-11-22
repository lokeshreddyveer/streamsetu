using System.Text.Json;

namespace StreamSetu.Core.SmartMix;

/// <summary>Keeps the shown-history and the reshuffle counter of one profile on disk (the profile's own store). Restricted items are never written: callers hand the engine's output, which has none.</summary>
public sealed class SmartMixStore(LocalStore store)
{
    private sealed record ShelfDto(string Shelf, long Seq, string LoadKey, List<SmartMixState.Row> Rows);
    private sealed record Dto(string Day, long Refresh, List<ShelfDto> Shelves);

    public SmartMixState State { get; private set; } = new();
    public string Day { get; private set; } = "";
    public long Refresh { get; private set; }

    private const string Name = "SmartMix";
    private const string Profile = "me";

    /// <summary>Loads the saved state. A new day starts the counter again at 0 (the day key is part of every load key anyway).</summary>
    public SmartMixStore Open(string dayKey)
    {
        var dto = store.Load<Dto?>(Name, null);
        State = new SmartMixState();
        if (dto is not null)
        {
            foreach (var s in dto.Shelves)
            {
                var sh = State.Get(Profile, s.Shelf);
                sh.Seq = s.Seq; sh.LoadKey = s.LoadKey; sh.Rows = s.Rows;
            }
            Refresh = dto.Day == dayKey ? dto.Refresh : 0;
        }
        else Refresh = 0;
        Day = dayKey;
        return this;
    }

    /// <summary>The profile name the state is kept under inside this store (one store per person).</summary>
    public static string ProfileKey => Profile;

    /// <summary>Another arrangement of the same library. Never starts a sync: it only changes the counter that seeds the draw.</summary>
    public void Reshuffle() { Refresh++; Save(); }

    public void Save()
    {
        var shelves = new List<ShelfDto>();
        foreach (var id in KnownShelves) { var s = State.Get(Profile, id); if (s.Seq > 0) shelves.Add(new ShelfDto(id, s.Seq, s.LoadKey, s.Rows)); }
        store.Save(Name, new Dto(Day, Refresh, shelves));
    }

    private static readonly string[] KnownShelves = { "hero", "for-you", "rediscover", "lang-pref", "top-week", "trending-library" };

    /// <summary>Forgets what was shown (a lock or hide change: nothing identifying restricted content stays).</summary>
    public void Purge() { State.Purge(Profile); Save(); }
}
