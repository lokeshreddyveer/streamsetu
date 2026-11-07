using System.Text.Json;

namespace StreamSetu.Core;

public sealed record Progress(double Position, double Duration, long At);

/// <summary>Playlists, favourites and resume points, kept as small files in one folder. Writes go to a temporary file first so a crash never leaves half a file, and a file that cannot be
/// read is set aside (never overwritten) so the person's data is not lost to a bad write. Passwords are not here: they live in Windows Credential Manager.</summary>
public sealed class LocalStore
{
    private readonly string _folder;
    private readonly Func<long> _now;
    private readonly object _gate = new();
    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true, PropertyNameCaseInsensitive = true, Converters = { new System.Text.Json.Serialization.JsonStringEnumConverter() } };

    public LocalStore(string folder, Func<long>? now = null)
    {
        _folder = folder; _now = now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        Directory.CreateDirectory(folder);
    }

    private string PathOf(string name) => Path.Combine(_folder, name + ".json");

    private T Read<T>(string name, T fallback)
    {
        var path = PathOf(name);
        if (!File.Exists(path)) return fallback;
        try { return JsonSerializer.Deserialize<T>(File.ReadAllText(path), Options) ?? fallback; }
        catch (Exception e) when (e is JsonException or IOException)
        {
            // Keep the unreadable file for inspection instead of letting the next save replace it.
            try { File.Move(path, path + ".unreadable-" + _now(), overwrite: true); } catch (IOException) { }
            return fallback;
        }
    }

    private void Write<T>(string name, T value)
    {
        var path = PathOf(name); var temp = path + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(value, Options));
        File.Move(temp, path, overwrite: true);
    }

    /// <summary>Anything else a feature keeps (its own file, same safety rules).</summary>
    public T Load<T>(string name, T fallback) { lock (_gate) return Read(name, fallback); }
    public void Save<T>(string name, T value) { lock (_gate) Write(name, value); }
    public string Folder => _folder;

    // --- Playlists ---
    public List<Playlist> Playlists() { lock (_gate) return Read(nameof(Playlists), new List<Playlist>()); }
    public void AddPlaylist(Playlist p) { lock (_gate) { var l = Read(nameof(Playlists), new List<Playlist>()); l.RemoveAll(x => x.Id == p.Id); l.Add(p); Write(nameof(Playlists), l); } }
    public void RemovePlaylist(string id) { lock (_gate) { var l = Read(nameof(Playlists), new List<Playlist>()); l.RemoveAll(x => x.Id == id); Write(nameof(Playlists), l); } }

    // --- Favourites, newest first ---
    public List<string> Favorites() { lock (_gate) return Read(nameof(Favorites), new List<string>()); }
    public bool IsFavorite(string id) => Favorites().Contains(id);
    /// <summary>Adds or removes; returns true when it is now a favourite.</summary>
    public bool ToggleFavorite(string id)
    {
        lock (_gate)
        {
            var l = Read(nameof(Favorites), new List<string>());
            bool removed = l.Remove(id);
            if (!removed) l.Insert(0, id);
            Write(nameof(Favorites), l);
            return !removed;
        }
    }

    // --- Resume points ---
    private Dictionary<string, Progress> AllProgress() => Read(nameof(Progress), new Dictionary<string, Progress>());
    public Progress? ProgressOf(string id) { lock (_gate) return AllProgress().GetValueOrDefault(id); }

    /// <summary>Remembered while watching. A title within its last 30 seconds, or 95% through, counts as finished and is forgotten; the first 10 seconds are not worth remembering.</summary>
    public void SaveProgress(string id, double position, double duration)
    {
        lock (_gate)
        {
            var all = AllProgress();
            if (duration > 0 && (duration - position < 30 || position / duration > 0.95)) { all.Remove(id); MarkWatchedLocked(id); }
            else if (position > 10) all[id] = new Progress(position, duration, _now());
            Write(nameof(Progress), all.OrderByDescending(kv => kv.Value.At).Take(300).ToDictionary(kv => kv.Key, kv => kv.Value));
        }
    }

    // --- Used when another device's changes arrive (Wi-Fi sync) ---
    public void AddFavorite(string id) { lock (_gate) { var l = Read(nameof(Favorites), new List<string>()); if (!l.Contains(id)) { l.Insert(0, id); Write(nameof(Favorites), l); } } }
    public void RemoveFavorite(string id) { lock (_gate) { var l = Read(nameof(Favorites), new List<string>()); if (l.Remove(id)) Write(nameof(Favorites), l); } }
    public void SetProgress(string id, double position, double duration, long atMs)
    {
        lock (_gate) { var all = AllProgress(); all[id] = new Progress(position, duration, atMs); Write(nameof(Progress), all.OrderByDescending(kv => kv.Value.At).Take(300).ToDictionary(kv => kv.Key, kv => kv.Value)); }
    }
    public void ClearProgress(string id) { lock (_gate) { var all = AllProgress(); if (all.Remove(id)) Write(nameof(Progress), all); } }

    // --- Watched: finished titles, for the green tick and the Unwatched lists ---
    private void MarkWatchedLocked(string id) { var w = Read(nameof(Watched), new List<string>()); if (!w.Contains(id)) { w.Add(id); Write(nameof(Watched), w); } }
    public HashSet<string> Watched() { lock (_gate) return Read(nameof(Watched), new List<string>()).ToHashSet(); }
    public void MarkWatched(string id) { lock (_gate) MarkWatchedLocked(id); }
    public void MarkUnwatched(string id) { lock (_gate) { var w = Read(nameof(Watched), new List<string>()); if (w.Remove(id)) Write(nameof(Watched), w); } }

    /// <summary>Titles left part-way, most recent first.</summary>
    public List<KeyValuePair<string, Progress>> RecentProgress() { lock (_gate) return AllProgress().OrderByDescending(kv => kv.Value.At).ToList(); }
}
