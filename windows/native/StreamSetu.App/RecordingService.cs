using Microsoft.UI.Dispatching;
using StreamSetu.Core;

namespace StreamSetu.App;

/// <summary>Starts scheduled recordings when their time comes and keeps their state. Runs while the app is open; a recording whose time passed while it was closed is marked as missed.</summary>
internal static class RecordingService
{
    private static readonly Dictionary<string, CancellationTokenSource> Running = new();
    private static DispatcherQueueTimer? _timer;

    public static string Folder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyVideos), "StreamSetu");
    public static event Action? Changed;

    public static void Start(DispatcherQueue queue)
    {
        AppServices.Recordings.SettleMissed(DateTimeOffset.UtcNow);
        _timer = queue.CreateTimer(); _timer.Interval = TimeSpan.FromSeconds(10); _timer.Tick += (_, _) => Tick();
        _timer.Start();
    }

    public static bool IsRunning(string id) { lock (Running) return Running.ContainsKey(id); }

    private static void Tick()
    {
        foreach (var rec in AppServices.Recordings.Due(DateTimeOffset.UtcNow))
        {
            lock (Running) { if (Running.ContainsKey(rec.Id)) continue; Running[rec.Id] = new CancellationTokenSource(); }
            _ = RunAsync(rec);
        }
    }

    private static async Task RunAsync(Recording rec)
    {
        CancellationTokenSource cts; lock (Running) cts = Running[rec.Id];
        AppServices.Recordings.Update(rec with { Status = RecordingStatus.Recording });
        Changed?.Invoke();
        Recording result;
        try
        {
            // A Stalker portal hands out a short-lived link, so the placeholder is turned into one now, when the recording starts.
            var url = rec.Url;
            if (rec.Url.StartsWith(StalkerClient.Scheme, StringComparison.Ordinal) && AppServices.Playlists().FirstOrDefault(p => p.Kind == PlaylistKind.Stalker) is { } portal) url = await AppServices.PlayUrlAsync(portal, rec.Url);
            result = await new Recorder(AppServices.Http, Folder).RunAsync(rec with { Url = url }, cts.Token);
        }
        catch (Exception e) { result = rec with { Status = RecordingStatus.Failed, Message = e.Message }; }
        AppServices.Recordings.Update(result with { Url = rec.Url });
        lock (Running) Running.Remove(rec.Id);
        Changed?.Invoke();
    }

    /// <summary>Stops a recording that is running; what was saved is kept.</summary>
    public static void Stop(string id) { lock (Running) if (Running.TryGetValue(id, out var cts)) cts.Cancel(); }
    public static void StopAll() { lock (Running) foreach (var cts in Running.Values) cts.Cancel(); }
}
