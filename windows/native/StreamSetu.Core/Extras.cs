using System.Globalization;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace StreamSetu.Core;

// =====================================================================================================================================================
// Channel logos and posters
// =====================================================================================================================================================

public interface IBytesFetcher { Task<byte[]> FetchBytesAsync(string url, long limit, CancellationToken ct = default); }

public sealed class SafeBytesFetcher(SafeHttp http) : IBytesFetcher
{
    public Task<byte[]> FetchBytesAsync(string url, long limit, CancellationToken ct = default) => http.FetchBytesAsync(url, limit, ct);
}

/// <summary>Pictures from providers, fetched through the safe downloader, checked to be pictures, and kept on disk so a list scrolls without asking again.</summary>
public sealed class LogoCache(IBytesFetcher fetcher, string folder, long maxBytes = 300L * 1024 * 1024)
{
    public const long MaxPicture = 3L * 1024 * 1024;
    private readonly SemaphoreSlim _slots = new(6);                                    // at most six pictures being fetched at once
    private readonly Dictionary<string, Task<byte[]?>> _inFlight = new();

    /// <summary>True for PNG, JPEG, GIF and WebP by their first bytes. A server that answers with a web page or a program is not a picture.</summary>
    public static bool LooksLikePicture(ReadOnlySpan<byte> b) =>
        (b.Length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47)
        || (b.Length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF)
        || (b.Length > 6 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x38)
        || (b.Length > 12 && b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50);

    public static string FileNameFor(string url) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(url)))[..32].ToLowerInvariant() + ".img";

    /// <summary>The picture, from disk if it is there, otherwise fetched. Null when there is none: a missing logo is never an error on screen. Asking for the same address twice at once fetches once.</summary>
    public Task<byte[]?> GetAsync(string? url, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(url) || !Uri.TryCreate(url, UriKind.Absolute, out var u) || (u.Scheme != Uri.UriSchemeHttp && u.Scheme != Uri.UriSchemeHttps)) return Task.FromResult<byte[]?>(null);
        lock (_inFlight)
        {
            if (_inFlight.TryGetValue(url, out var running)) return running;
            var task = LoadAsync(url, ct);
            _inFlight[url] = task;
            _ = task.ContinueWith(_ => { lock (_inFlight) _inFlight.Remove(url); }, TaskScheduler.Default);
            return task;
        }
    }

    private async Task<byte[]?> LoadAsync(string url, CancellationToken ct)
    {
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, FileNameFor(url));
        try { if (File.Exists(path)) { var cached = await File.ReadAllBytesAsync(path, ct).ConfigureAwait(false); if (LooksLikePicture(cached)) return cached; File.Delete(path); } }
        catch (IOException) { }
        await _slots.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            var bytes = await fetcher.FetchBytesAsync(url, MaxPicture, ct).ConfigureAwait(false);
            if (!LooksLikePicture(bytes)) return null;
            try { await File.WriteAllBytesAsync(path, bytes, ct).ConfigureAwait(false); Prune(); } catch (IOException) { }
            return bytes;
        }
        catch (Exception e) when (e is InvalidOperationException or FetchRefusedException or HttpRequestException) { return null; }
        finally { _slots.Release(); }
    }

    /// <summary>When the folder passes its limit, the least recently written pictures go first.</summary>
    private void Prune()
    {
        try
        {
            var files = new DirectoryInfo(folder).GetFiles("*.img").OrderBy(f => f.LastWriteTimeUtc).ToList();
            long total = files.Sum(f => f.Length);
            foreach (var f in files) { if (total <= maxBytes) break; total -= f.Length; f.Delete(); }
        }
        catch (IOException) { }
    }
}

// =====================================================================================================================================================
// Skip intro, recap and credits (from the chapters a file carries)
// =====================================================================================================================================================

public sealed record Chapter(string Title, double Start);
public sealed record SkipOffer(string Label, double Target);

public static class SkipMarkers
{
    private static readonly Regex Intro = new(@"\b(intro|opening|op|title sequence|main title)\b", RegexOptions.IgnoreCase | RegexOptions.ECMAScript);
    private static readonly Regex Recap = new(@"\b(recap|previously|previously on)\b", RegexOptions.IgnoreCase | RegexOptions.ECMAScript);
    private static readonly Regex Credits = new(@"\b(credits|ending|outro|end credits|ed)\b", RegexOptions.IgnoreCase | RegexOptions.ECMAScript);

    /// <summary>The button to offer at <paramref name="position"/>, if a chapter named like an intro, recap or credits is playing; where it jumps to is the start of the next chapter (or the end).</summary>
    public static SkipOffer? Offer(IReadOnlyList<Chapter> chapters, double position, double duration)
    {
        var ordered = chapters.OrderBy(c => c.Start).ToList();
        for (int i = 0; i < ordered.Count; i++)
        {
            var end = i + 1 < ordered.Count ? ordered[i + 1].Start : duration;
            if (position < ordered[i].Start || position >= end || end <= ordered[i].Start || end <= 0) continue;
            var t = ordered[i].Title;
            string? label = Recap.IsMatch(t) ? "Skip recap" : Intro.IsMatch(t) ? "Skip intro" : Credits.IsMatch(t) ? "Skip credits" : null;
            // The last second is not worth a button, and a chapter that is the whole film (a single chapter) is not an intro.
            if (label is not null && end - position > 2 && ordered.Count > 1) return new SkipOffer(label, end);
            return null;
        }
        return null;
    }
}

// =====================================================================================================================================================
// Programme reminders
// =====================================================================================================================================================

public sealed record Reminder(string Id, string Channel, string Title, DateTimeOffset Start, int LeadMinutes, bool Fired = false);

public sealed class ReminderStore(LocalStore store)
{
    private List<Reminder> Load() => store.Load("Reminders", new List<Reminder>());
    public List<Reminder> All() => Load().OrderBy(r => r.Start).ToList();

    /// <summary>Adds one; the same programme on the same channel is not added twice. Returns false when it already was, or has already started.</summary>
    public bool Add(string channel, string title, DateTimeOffset start, int leadMinutes, DateTimeOffset now)
    {
        if (start <= now) return false;
        var all = Load();
        if (all.Any(r => r.Channel == channel && r.Start == start)) return false;
        all.Add(new Reminder(Guid.NewGuid().ToString("N")[..10], channel, title, start, Math.Clamp(leadMinutes, 0, 120)));
        store.Save("Reminders", all);
        return true;
    }

    public void Remove(string id) { var all = Load(); if (all.RemoveAll(r => r.Id == id) > 0) store.Save("Reminders", all); }

    /// <summary>Reminders whose time has come and that have not been shown: from the lead time before the start until five minutes after (an app opened late still says so, an old one does not).</summary>
    public List<Reminder> Due(DateTimeOffset now) => Load().Where(r => !r.Fired && now >= r.Start.AddMinutes(-r.LeadMinutes) && now < r.Start.AddMinutes(5)).ToList();

    public void MarkFired(string id) { var all = Load(); var i = all.FindIndex(r => r.Id == id); if (i >= 0) { all[i] = all[i] with { Fired = true }; store.Save("Reminders", all); } }

    /// <summary>Forgets reminders that are long past.</summary>
    public void Prune(DateTimeOffset now) { var all = Load(); if (all.RemoveAll(r => r.Start < now.AddHours(-1)) > 0) store.Save("Reminders", all); }
}

// =====================================================================================================================================================
// Scheduled recording
// =====================================================================================================================================================

public enum RecordingStatus { Scheduled, Recording, Done, Failed, Cancelled }

public sealed record Recording(string Id, string Name, string Url, DateTimeOffset Start, DateTimeOffset Stop, RecordingStatus Status = RecordingStatus.Scheduled, string? Message = null, string? Path = null, long Bytes = 0);

public sealed class RecordingStore(LocalStore store)
{
    private List<Recording> Load() => store.Load("Recordings", new List<Recording>());
    public List<Recording> All() => Load().OrderBy(r => r.Start).ToList();

    /// <summary>Schedules a recording, a minute early and two minutes late so the start and end of a programme are not cut off. A recording that clashes with another is allowed, but says so (a provider often allows one stream at a time).</summary>
    public (Recording Recording, string? Warning) Add(string name, string url, DateTimeOffset start, DateTimeOffset stop, DateTimeOffset now, bool padding = true)
    {
        if (stop <= start) throw new ArgumentException("A recording must end after it starts.");
        if (stop <= now) throw new ArgumentException("That programme has already ended.");
        if (stop - start > TimeSpan.FromHours(12)) throw new ArgumentException("A recording can be at most 12 hours.");
        if (!Uri.TryCreate(url, UriKind.Absolute, out var u) || (u.Scheme != Uri.UriSchemeHttp && u.Scheme != Uri.UriSchemeHttps)) throw new ArgumentException("Only web addresses can be recorded.");
        var rec = new Recording(Guid.NewGuid().ToString("N")[..10], name.Trim().Length > 0 ? name.Trim() : "Recording", url, padding ? start.AddMinutes(-1) : start, padding ? stop.AddMinutes(2) : stop);
        var all = Load();
        var clash = all.FirstOrDefault(r => r.Status is RecordingStatus.Scheduled or RecordingStatus.Recording && r.Start < rec.Stop && rec.Start < r.Stop);
        all.Add(rec); store.Save("Recordings", all);
        return (rec, clash is null ? null : $"This overlaps “{clash.Name}”. Many providers allow only one stream at a time, so one of them may fail.");
    }

    public void Update(Recording r) { var all = Load(); var i = all.FindIndex(x => x.Id == r.Id); if (i >= 0) { all[i] = r; store.Save("Recordings", all); } }
    public void Remove(string id) { var all = Load(); if (all.RemoveAll(r => r.Id == id) > 0) store.Save("Recordings", all); }

    /// <summary>Scheduled recordings whose time has come.</summary>
    public List<Recording> Due(DateTimeOffset now) => Load().Where(r => r.Status == RecordingStatus.Scheduled && now >= r.Start && now < r.Stop).ToList();

    /// <summary>Marks what could not happen: a recording that should have begun while the app was closed, and one that was running when the app was closed.</summary>
    public void SettleMissed(DateTimeOffset now)
    {
        var all = Load(); bool changed = false;
        for (int i = 0; i < all.Count; i++)
        {
            if (all[i].Status == RecordingStatus.Scheduled && all[i].Stop <= now) { all[i] = all[i] with { Status = RecordingStatus.Failed, Message = "StreamSetu was not running at that time." }; changed = true; }
            else if (all[i].Status == RecordingStatus.Recording) { all[i] = all[i] with { Status = RecordingStatus.Failed, Message = "StreamSetu was closed during the recording; what was saved is kept." }; changed = true; }
        }
        if (changed) store.Save("Recordings", all);
    }
}

public sealed class Recorder(SafeHttp http, string folder, Func<DateTimeOffset>? now = null, long minFreeBytes = 1L << 30)
{
    private readonly Func<DateTimeOffset> _now = now ?? (() => DateTimeOffset.UtcNow);

    /// <summary>A file name made from the programme's name: no characters Windows refuses, no path, not too long, never an existing file.</summary>
    public static string SafeName(string name, DateTimeOffset start)
    {
        var cleaned = new string(name.Select(c => char.IsControl(c) || Path.GetInvalidFileNameChars().Contains(c) || c is ':' or '*' or '?' or '"' or '<' or '>' or '|' or '/' or '\\' ? ' ' : c).ToArray()).Trim(' ', '.');
        cleaned = Regex.Replace(cleaned, @"\s+", " ");
        if (cleaned.Length > 80) cleaned = cleaned[..80].Trim();
        if (cleaned.Length == 0) cleaned = "Recording";
        if (Regex.IsMatch(cleaned, @"^(con|prn|aux|nul|com[1-9]|lpt[1-9])$", RegexOptions.IgnoreCase)) cleaned = "_" + cleaned;
        return $"{cleaned} {start.ToLocalTime():yyyy-MM-dd HH-mm}.ts";
    }

    /// <summary>Copies the stream into a file until the recording's end time. Returns the finished recording; a failure is in the result, not thrown.</summary>
    public async Task<Recording> RunAsync(Recording rec, CancellationToken ct)
    {
        Directory.CreateDirectory(folder);
        var root = Path.GetFullPath(folder) + Path.DirectorySeparatorChar;
        var path = Path.GetFullPath(Path.Combine(folder, SafeName(rec.Name, rec.Start)));
        if (!path.StartsWith(root, StringComparison.OrdinalIgnoreCase)) return rec with { Status = RecordingStatus.Failed, Message = "That name cannot be used for a file." };
        for (int n = 2; File.Exists(path); n++) path = Path.Combine(folder, Path.GetFileNameWithoutExtension(SafeName(rec.Name, rec.Start)) + $" ({n}).ts");
        try { if (new DriveInfo(Path.GetPathRoot(path)!).AvailableFreeSpace < minFreeBytes) return rec with { Status = RecordingStatus.Failed, Message = "There is less than 1 GB free on the disk." }; }
        catch (Exception e) when (e is ArgumentException or IOException or UnauthorizedAccessException) { }

        using var until = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var remaining = rec.Stop - _now();
        if (remaining <= TimeSpan.Zero) return rec with { Status = RecordingStatus.Failed, Message = "The time for this recording has passed." };
        until.CancelAfter(remaining);
        long bytes = 0;
        try
        {
            using var response = await http.GetAsync(rec.Url, null, until.Token).ConfigureAwait(false);
            if ((int)response.StatusCode >= 400) return rec with { Status = RecordingStatus.Failed, Message = $"The server answered {(int)response.StatusCode}." };
            await using var input = await response.Content.ReadAsStreamAsync(until.Token).ConfigureAwait(false);
            await using var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
            var buffer = new byte[256 * 1024]; int read;
            while ((read = await input.ReadAsync(buffer, until.Token).ConfigureAwait(false)) > 0) { await output.WriteAsync(buffer.AsMemory(0, read), CancellationToken.None).ConfigureAwait(false); bytes += read; }
            return bytes == 0 ? rec with { Status = RecordingStatus.Failed, Message = "The stream sent nothing.", Path = null } : rec with { Status = RecordingStatus.Done, Path = path, Bytes = bytes, Message = null };
        }
        catch (OperationCanceledException)
        {
            // The end time, or the person stopping it: what was saved is kept.
            var stoppedByPerson = ct.IsCancellationRequested;
            return bytes > 0 ? rec with { Status = stoppedByPerson ? RecordingStatus.Cancelled : RecordingStatus.Done, Path = path, Bytes = bytes } : rec with { Status = stoppedByPerson ? RecordingStatus.Cancelled : RecordingStatus.Failed, Message = "The stream sent nothing." };
        }
        catch (FetchRefusedException e) { return rec with { Status = RecordingStatus.Failed, Message = e.Message }; }
        catch (IOException e) { return rec with { Status = bytes > 0 ? RecordingStatus.Done : RecordingStatus.Failed, Path = bytes > 0 ? path : null, Bytes = bytes, Message = bytes > 0 ? "The recording stopped early: " + e.Message : e.Message }; }
    }
}

// =====================================================================================================================================================
// Multi-View: several channels at once
// =====================================================================================================================================================

public readonly record struct Tile(int X, int Y, int Width, int Height);

public static class MultiViewLayout
{
    public const int MaxTiles = 4;

    /// <summary>Where each tile goes: one fills the area, two sit side by side, three or four make two rows of two. Tiles are separated by <paramref name="gap"/> and never overlap.</summary>
    public static List<Tile> Tiles(int count, int width, int height, int gap = 4)
    {
        count = Math.Clamp(count, 0, MaxTiles);
        var tiles = new List<Tile>();
        if (count == 0 || width <= 0 || height <= 0) return tiles;
        int cols = count == 1 ? 1 : 2, rows = count <= 2 ? 1 : 2;
        int tw = Math.Max(1, (width - gap * (cols - 1)) / cols), th = Math.Max(1, (height - gap * (rows - 1)) / rows);
        for (int i = 0; i < count; i++) tiles.Add(new Tile(i % cols * (tw + gap), i / cols * (th + gap), tw, th));
        return tiles;
    }
}

// =====================================================================================================================================================
// Updates
// =====================================================================================================================================================

public sealed record UpdateInfo(Version Version, string AssetName, string DownloadUrl, string Sha256, string Notes);

public static class Updates
{
    public const string ReleasesPrefix = "https://github.com/lokeshreddyveer/streamsetu/releases/download/";
    private static readonly Regex AssetPattern = new(@"^StreamSetu-Setup-(\d+(?:\.\d+){1,3})\.exe$", RegexOptions.ECMAScript);

    /// <summary>The update in a GitHub "latest release" answer, if there is one newer than <paramref name="current"/>. The file name must be exactly ours and the address must be in our releases, so a changed release page cannot point the updater anywhere else; the SHA-256 comes from the release notes.</summary>
    public static UpdateInfo? Parse(string releaseJson, Version current)
    {
        System.Text.Json.JsonElement root;
        try { root = System.Text.Json.JsonDocument.Parse(releaseJson).RootElement; } catch (System.Text.Json.JsonException) { throw new InvalidOperationException("The update service answered in a form StreamSetu does not understand."); }
        if (root.ValueKind != System.Text.Json.JsonValueKind.Object || !root.TryGetProperty("assets", out var assets) || assets.ValueKind != System.Text.Json.JsonValueKind.Array) return null;
        var body = root.TryGetProperty("body", out var b) && b.ValueKind == System.Text.Json.JsonValueKind.String ? b.GetString() ?? "" : "";
        foreach (var a in assets.EnumerateArray())
        {
            var name = a.TryGetProperty("name", out var n) && n.ValueKind == System.Text.Json.JsonValueKind.String ? n.GetString() : null;
            var url = a.TryGetProperty("browser_download_url", out var u) && u.ValueKind == System.Text.Json.JsonValueKind.String ? u.GetString() : null;
            if (name is null || url is null || AssetPattern.Match(name) is not { Success: true } m) continue;
            if (!url.StartsWith(ReleasesPrefix, StringComparison.Ordinal) || !url.EndsWith("/" + name, StringComparison.Ordinal) || url.Contains("..") || url.Contains('?')) continue;
            if (!Version.TryParse(m.Groups[1].Value, out var version) || version <= current) continue;
            var sha = Regex.Match(body, @"`" + Regex.Escape(name) + @"`\s+([0-9a-fA-F]{64})");
            if (!sha.Success) continue;                                                                  // no checksum, no update
            return new UpdateInfo(version, name, url, sha.Groups[1].Value.ToLowerInvariant(), body);
        }
        return null;
    }

    public static bool Matches(ReadOnlySpan<byte> file, string expectedSha256) =>
        CryptographicOperations.FixedTimeEquals(SHA256.HashData(file), Convert.FromHexString(expectedSha256));

    /// <summary>Downloads the installer and keeps it only when its checksum is right.</summary>
    public static async Task<string> DownloadAsync(SafeHttp http, UpdateInfo info, string folder, CancellationToken ct = default)
    {
        var bytes = await http.FetchBytesAsync(info.DownloadUrl, 300L * 1024 * 1024, ct).ConfigureAwait(false);
        if (!Matches(bytes, info.Sha256)) throw new InvalidOperationException("The downloaded update does not match its checksum, so it was not kept.");
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, info.AssetName);
        await File.WriteAllBytesAsync(path, bytes, ct).ConfigureAwait(false);
        return path;
    }
}

// =====================================================================================================================================================
// Encrypted DNS for the player's own lookups
// =====================================================================================================================================================

public sealed record PinnedAddress(string Url, string? HostHeader);

public static class Pinning
{
    /// <summary>mpv looks names up with the system. To use the encrypted resolver for it too, an http:// address is rewritten to the address that was found, with a Host header carrying the name. https:// is left alone (the certificate is for the name, so an address would fail),
    /// and so is anything already numeric. A name that resolves only to this computer or network is left to the system unless the host is in a connection. Redirects to other names are still looked up by the system.</summary>
    public static async Task<PinnedAddress> PinAsync(string url, IHostResolver resolver, HostAllowList allow, CancellationToken ct = default)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var u) || u.Scheme != Uri.UriSchemeHttp || IPAddress.TryParse(u.Host.Trim('[', ']'), out _)) return new PinnedAddress(url, null);
        try
        {
            var addresses = await resolver.ResolveAsync(u.Host, ct).ConfigureAwait(false);
            var chosen = addresses.FirstOrDefault(a => allow.Contains(u.Host) || !AddressPolicy.IsBlocked(a));
            if (chosen is null) return new PinnedAddress(url, null);
            var host = chosen.AddressFamily == System.Net.Sockets.AddressFamily.InterNetworkV6 ? $"[{chosen}]" : chosen.ToString();
            var builder = new UriBuilder(u) { Host = host };
            return new PinnedAddress(builder.Uri.AbsoluteUri, u.IsDefaultPort ? u.Host : $"{u.Host}:{u.Port}");
        }
        catch (Exception e) when (e is System.Net.Sockets.SocketException or HttpRequestException or InvalidOperationException or ArgumentException or OperationCanceledException && !ct.IsCancellationRequested) { return new PinnedAddress(url, null); }
    }
}
