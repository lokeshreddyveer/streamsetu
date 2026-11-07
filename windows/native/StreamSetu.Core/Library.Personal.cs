namespace StreamSetu.Core;

public sealed record FolderView(string Name, string Display, bool Locked);

/// <summary>Folders (the groups a connection lists): reorder, hide, rename and lock with a PIN. Kept per profile. In a Kids profile a locked folder is not shown at all.</summary>
public sealed class FolderPrefs(LocalStore store)
{
    private sealed record Pref(bool Hidden = false, string? Rename = null, PinHash? Lock = null);
    private sealed record State(Dictionary<string, Pref> Prefs, Dictionary<string, List<string>> Orders);

    private State Load() => store.Load("Folders", new State(new(), new()));
    private static string Key(string scope, string group) => scope + "|" + group;

    public void Hide(string scope, string group, bool hidden) => Edit(scope, group, p => p with { Hidden = hidden });
    public void Rename(string scope, string group, string? name) => Edit(scope, group, p => p with { Rename = string.IsNullOrWhiteSpace(name) ? null : name.Trim() });
    public void SetLock(string scope, string group, string? pin) => Edit(scope, group, p => p with { Lock = pin is null ? null : PinHash.Make(pin) });
    public bool IsLocked(string scope, string group) => Load().Prefs.GetValueOrDefault(Key(scope, group))?.Lock is not null;
    public bool Unlock(string scope, string group, string pin) => Load().Prefs.GetValueOrDefault(Key(scope, group))?.Lock is { } l && l.Matches(pin);

    /// <summary>Resetting a folder's name, hiding and order back to the provider's. A locked folder needs its PIN to be reset, otherwise this would be a way round the lock.</summary>
    public bool Reset(string scope, string group, string? pin)
    {
        var s = Load(); var key = Key(scope, group);
        if (s.Prefs.GetValueOrDefault(key)?.Lock is { } l && (pin is null || !l.Matches(pin))) return false;
        s.Prefs.Remove(key); store.Save("Folders", s);
        return true;
    }

    private void Edit(string scope, string group, Func<Pref, Pref> change)
    {
        var s = Load(); var key = Key(scope, group);
        // Changing a locked folder's settings (other than its lock) is not allowed without unlocking first; callers verify the PIN, then call here.
        s.Prefs[key] = change(s.Prefs.GetValueOrDefault(key) ?? new Pref());
        store.Save("Folders", s);
    }

    public void MoveUp(string scope, IReadOnlyList<string> groups, string group) => Move(scope, groups, group, -1);
    public void MoveDown(string scope, IReadOnlyList<string> groups, string group) => Move(scope, groups, group, 1);

    private void Move(string scope, IReadOnlyList<string> groups, string group, int by)
    {
        var s = Load();
        var order = Ordered(groups, s.Orders.GetValueOrDefault(scope));
        var i = order.IndexOf(group); var j = i + by;
        if (i < 0 || j < 0 || j >= order.Count) return;
        (order[i], order[j]) = (order[j], order[i]);
        s.Orders[scope] = order; store.Save("Folders", s);
    }

    private static List<string> Ordered(IEnumerable<string> groups, List<string>? saved)
    {
        var all = groups.Distinct().ToList();
        if (saved is null) return all;
        return saved.Where(all.Contains).Concat(all.Where(g => !saved.Contains(g))).ToList();
    }

    /// <summary>The folders to show, in the person's order, without hidden ones (and without locked ones in a Kids profile).</summary>
    public List<FolderView> Visible(string scope, IEnumerable<string> groups, bool kids)
    {
        var s = Load();
        var views = new List<FolderView>();
        foreach (var g in Ordered(groups, s.Orders.GetValueOrDefault(scope)))
        {
            var p = s.Prefs.GetValueOrDefault(Key(scope, g));
            var locked = p?.Lock is not null;
            if (p?.Hidden == true || (kids && locked)) continue;
            views.Add(new FolderView(g, p?.Rename ?? g, locked));
        }
        return views;
    }
}

/// <summary>The person's own lists of titles. Items are named by their key (connection id, then the title's id), so they survive a refresh of the connection.</summary>
public sealed class Collections(LocalStore store)
{
    public sealed record Collection(string Id, string Name, List<string> Keys);

    private List<Collection> Load() => store.Load("Collections", new List<Collection>());

    public List<Collection> All() => Load();

    public Collection Create(string name)
    {
        name = name.Trim();
        if (name.Length == 0) throw new ArgumentException("A collection needs a name.");
        var all = Load();
        if (all.Any(c => string.Equals(c.Name, name, StringComparison.CurrentCultureIgnoreCase))) throw new InvalidOperationException("There is already a collection with that name.");
        var c = new Collection(Guid.NewGuid().ToString("N")[..10], name, new());
        all.Add(c); store.Save("Collections", all);
        return c;
    }

    /// <summary>Creates a collection with a given id (one that arrived from another device) or renames it.</summary>
    public void Upsert(string id, string name)
    {
        var all = Load(); var i = all.FindIndex(c => c.Id == id); name = name.Trim().Length > 0 ? name.Trim() : "Collection";
        if (i >= 0) all[i] = all[i] with { Name = name }; else all.Add(new Collection(id, name, new()));
        store.Save("Collections", all);
    }

    public void Rename(string id, string name) { var all = Load(); var i = all.FindIndex(c => c.Id == id); if (i >= 0 && name.Trim().Length > 0) { all[i] = all[i] with { Name = name.Trim() }; store.Save("Collections", all); } }
    public void Delete(string id) { var all = Load(); if (all.RemoveAll(c => c.Id == id) > 0) store.Save("Collections", all); }

    public bool Add(string id, string key)
    {
        var all = Load(); var c = all.FirstOrDefault(x => x.Id == id);
        if (c is null || c.Keys.Contains(key)) return false;
        c.Keys.Add(key); store.Save("Collections", all);
        return true;
    }

    public void Remove(string id, string key) { var all = Load(); if (all.FirstOrDefault(x => x.Id == id) is { } c && c.Keys.Remove(key)) store.Save("Collections", all); }
}

/// <summary>Play Next and Add to Queue.</summary>
public sealed class PlayQueue
{
    public sealed record Entry(string Key, string Title, string Url);
    private readonly List<Entry> _items = new();
    public IReadOnlyList<Entry> Items => _items;

    public void PlayNext(Entry e) { Remove(e.Key); _items.Insert(0, e); }
    public void Add(Entry e) { if (_items.All(x => x.Key != e.Key)) _items.Add(e); }
    public void Remove(string key) => _items.RemoveAll(x => x.Key == key);
    public void Clear() => _items.Clear();

    /// <summary>Takes the next entry to play, or null when the queue is empty.</summary>
    public Entry? Next() { if (_items.Count == 0) return null; var e = _items[0]; _items.RemoveAt(0); return e; }
}

public enum WatchStatus { Any, Unwatched, Started }

/// <summary>The Sort menu's filters on movies and series.</summary>
public sealed record ItemFilter(string? Language = null, Quality MinQuality = Quality.Unknown, double MinRating = 0, int? Decade = null, WatchStatus Status = WatchStatus.Any)
{
    /// <param name="keyOf">The key progress and the watched list use for an item.</param>
    public List<Item> Apply(IEnumerable<Item> items, Func<Item, string> keyOf, ISet<string> watched, Func<string, bool> started)
        => items.Where(i =>
        {
            var tags = Tags.Of(i.Title);
            if (Language is not null && !string.Equals(tags.Language, Language, StringComparison.OrdinalIgnoreCase)) return false;
            if (MinQuality != Quality.Unknown && tags.Quality < MinQuality) return false;
            if (MinRating > 0 && !(i.Rating >= MinRating)) return false;
            if (Decade is { } d && !(i.Year >= d && i.Year < d + 10)) return false;
            var key = keyOf(i);
            return Status switch { WatchStatus.Unwatched => !watched.Contains(key), WatchStatus.Started => started(key), _ => true };
        }).ToList();
}

public static class SmartLists
{
    public static List<Item> Unwatched(IEnumerable<Item> items, Func<Item, string> keyOf, ISet<string> watched) => items.Where(i => !watched.Contains(keyOf(i))).ToList();

    public static List<Item> UnwatchedFavorites(IEnumerable<Item> items, Func<Item, string> keyOf, ISet<string> watched, ISet<string> favorites)
        => items.Where(i => favorites.Contains(keyOf(i)) && !watched.Contains(keyOf(i))).ToList();

    /// <summary>Titles the provider added in the last <paramref name="days"/> days, newest first. A title with no date is left out rather than guessed.</summary>
    public static List<Item> AddedWithin(IEnumerable<Item> items, DateTimeOffset now, int days)
        => items.Where(i => i.Added is { } a && a <= now && a >= now.AddDays(-days)).OrderByDescending(i => i.Added).ToList();
}
