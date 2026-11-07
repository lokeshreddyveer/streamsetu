namespace StreamSetu.Core;

public enum PlayState { Idle, Loading, Playing, Failed }

/// <summary>What actually plays: libmpv on Windows, a fake in tests. It only starts a stream; <see cref="PlaybackSession"/> decides which start counts.</summary>
public interface IPlayerBackend
{
    /// <summary>Begins playing. Completes when playback has started, throws when the stream cannot be played, and must stop early when <paramref name="ct"/> is cancelled.</summary>
    Task StartAsync(string url, double startAt, CancellationToken ct);
    void Stop();
}

/// <summary>One thing playing at a time. Starting something else supersedes the first: a load that was overtaken, or that finishes after Stop, must not change the state or reach the screen
/// (the same rule as the Mac app's MPV engine, where a late finish used to configure a destroyed player).</summary>
public sealed class PlaybackSession(IPlayerBackend backend)
{
    private int _generation;
    private CancellationTokenSource? _current;

    public PlayState State { get; private set; } = PlayState.Idle;
    public string? Url { get; private set; }
    public string? Error { get; private set; }
    public event Action? Changed;

    public async Task PlayAsync(string url, double startAt = 0)
    {
        var mine = Interlocked.Increment(ref _generation);
        var previous = _current; var cts = new CancellationTokenSource(); _current = cts;
        previous?.Cancel();
        backend.Stop();
        Url = url; Error = null; Set(PlayState.Loading);
        try
        {
            await backend.StartAsync(url, startAt, cts.Token).ConfigureAwait(false);
            if (mine == Volatile.Read(ref _generation)) Set(PlayState.Playing);
        }
        catch (OperationCanceledException) { /* superseded or stopped: nothing to report */ }
        catch (Exception e)
        {
            if (mine != Volatile.Read(ref _generation)) return;          // an old failure must not spoil the new stream
            Error = e.Message; Set(PlayState.Failed);
        }
    }

    public void Stop()
    {
        Interlocked.Increment(ref _generation);
        _current?.Cancel(); _current = null;
        backend.Stop();
        Url = null; Error = null; Set(PlayState.Idle);
    }

    private void Set(PlayState state) { State = state; Changed?.Invoke(); }
}
