using System.Text;

namespace StreamSetu.Core;

/// <summary>A title with no poster (or one that would not load) gets a designed tile: a colour that is the same every time for the same title, and its initials.</summary>
public static class Placeholders
{
    /// <summary>Up to two capital letters from the first two words ("The Matrix" gives "TM"); a title with none shows "#".</summary>
    public static string Monogram(string? title)
    {
        var letters = new StringBuilder();
        foreach (var w in IdentityKey.Words(title ?? "").Where(w => w.Length > 0).Take(2))
            letters.Append(char.ToUpperInvariant(w[0]));
        return letters.Length == 0 ? "#" : letters.ToString();
    }

    /// <summary>0..359, the same for the same title on every run.</summary>
    public static int Hue(string? title) => (int)(SmartMix.Fnv.Hash64(title ?? "") % 360);

    /// <summary>The titles with a poster first, then the ones without, each group in its own order.</summary>
    public static List<T> PosterFirst<T>(IEnumerable<T> items, Func<T, bool> hasPoster)
    {
        var all = items.ToList();
        return all.Where(hasPoster).Concat(all.Where(i => !hasPoster(i))).ToList();
    }

    /// <summary>Hue, saturation and value (0..1) to red, green, blue (0..255): a calm dark tile of that colour.</summary>
    public static (byte R, byte G, byte B) Rgb(int hue, double saturation = 0.45, double value = 0.42)
    {
        var h = (hue % 360) / 60.0; var c = value * saturation; var x = c * (1 - Math.Abs(h % 2 - 1)); var m = value - c;
        var (r, g, b) = (int)h switch { 0 => (c, x, 0.0), 1 => (x, c, 0.0), 2 => (0.0, c, x), 3 => (0.0, x, c), 4 => (x, 0.0, c), _ => (c, 0.0, x) };
        return ((byte)Math.Round((r + m) * 255), (byte)Math.Round((g + m) * 255), (byte)Math.Round((b + m) * 255));
    }
}

public static class Retry
{
    /// <summary>Runs <paramref name="work"/> until it gives something, at most <paramref name="attempts"/> times, pausing longer each time (0.5 s, 1 s, 2 s by default). Null after the last try.</summary>
    public static async Task<T?> RunAsync<T>(Func<Task<T?>> work, int attempts = 3, Func<int, TimeSpan>? pause = null, Func<TimeSpan, Task>? delay = null) where T : class
    {
        pause ??= n => TimeSpan.FromMilliseconds(500 * Math.Pow(2, n));
        delay ??= Task.Delay;
        for (var n = 0; n < Math.Max(1, attempts); n++)
        {
            try { if (await work() is { } got) return got; }
            catch (Exception e) when (e is HttpRequestException or IOException or InvalidOperationException) { /* try again */ }
            if (n < attempts - 1) await delay(pause(n));
        }
        return null;
    }
}

/// <summary>Pictures kept in memory for the tiles on screen, never more than a fixed number of bytes: the least recently used go first.</summary>
public sealed class ByteLru(long maxBytes)
{
    private readonly LinkedList<(string Key, byte[] Value)> _order = new();
    private readonly Dictionary<string, LinkedListNode<(string Key, byte[] Value)>> _map = new();
    private readonly object _gate = new();
    public long Bytes { get; private set; }
    public int Count { get { lock (_gate) return _map.Count; } }

    public bool TryGet(string key, out byte[] value)
    {
        lock (_gate)
        {
            if (_map.TryGetValue(key, out var node)) { _order.Remove(node); _order.AddFirst(node); value = node.Value.Value; return true; }
            value = Array.Empty<byte>(); return false;
        }
    }

    public void Put(string key, byte[] value)
    {
        if (value.Length > maxBytes) return;                       // one picture bigger than the whole budget is not kept
        lock (_gate)
        {
            if (_map.Remove(key, out var old)) { _order.Remove(old); Bytes -= old.Value.Value.Length; }
            _map[key] = _order.AddFirst((key, value)); Bytes += value.Length;
            while (Bytes > maxBytes && _order.Last is { } last) { _order.RemoveLast(); _map.Remove(last.Value.Key); Bytes -= last.Value.Value.Length; }
        }
    }
}
