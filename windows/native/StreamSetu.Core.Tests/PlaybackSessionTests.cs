using StreamSetu.Core;
using Xunit;

namespace StreamSetu.Core.Tests;

public class PlaybackSessionTests
{
    /// <summary>A player whose starts finish only when the test says so, and that records what it was told.</summary>
    private sealed class FakeBackend : IPlayerBackend
    {
        public Dictionary<string, TaskCompletionSource> Starts { get; } = new();
        public List<string> Log { get; } = new();
        public Task StartAsync(string url, double startAt, CancellationToken ct)
        {
            Log.Add("start " + url);
            var tcs = Starts[url] = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            ct.Register(() => tcs.TrySetCanceled(ct));
            return tcs.Task;
        }
        public void Stop() => Log.Add("stop");
    }

    [Fact]
    public async Task A_stream_that_starts_is_playing()
    {
        var b = new FakeBackend(); var s = new PlaybackSession(b);
        var play = s.PlayAsync("a"); Assert.Equal(PlayState.Loading, s.State);
        b.Starts["a"].SetResult(); await play;
        Assert.Equal(PlayState.Playing, s.State);
    }

    [Fact]
    public async Task A_stream_that_fails_reports_why()
    {
        var b = new FakeBackend(); var s = new PlaybackSession(b);
        var play = s.PlayAsync("a"); b.Starts["a"].SetException(new InvalidOperationException("No signal"));
        await play;
        Assert.Equal(PlayState.Failed, s.State); Assert.Equal("No signal", s.Error);
    }

    [Fact]
    public async Task A_load_that_was_overtaken_cannot_change_what_is_shown()
    {
        var b = new FakeBackend(); var s = new PlaybackSession(b);
        var first = s.PlayAsync("slow"); var second = s.PlayAsync("fast");
        b.Starts["fast"].SetResult(); await second;
        Assert.Equal(PlayState.Playing, s.State); Assert.Equal("fast", s.Url);
        await first;                                                           // the first load was cancelled; it finishes quietly
        Assert.Equal(PlayState.Playing, s.State); Assert.Equal("fast", s.Url);
    }

    [Fact]
    public async Task An_old_failure_does_not_spoil_the_newer_stream()
    {
        var b = new FakeBackend(); var s = new PlaybackSession(b);
        var first = s.PlayAsync("old"); var second = s.PlayAsync("new");
        b.Starts["old"].TrySetException(new InvalidOperationException("late failure"));
        b.Starts["new"].SetResult();
        await Task.WhenAll(first, second);
        Assert.Equal(PlayState.Playing, s.State); Assert.Null(s.Error);
    }

    [Fact]
    public async Task A_load_that_finishes_after_stop_does_not_start_playing()
    {
        var b = new FakeBackend(); var s = new PlaybackSession(b);
        var play = s.PlayAsync("a"); s.Stop();
        b.Starts["a"].TrySetResult(); await play;
        Assert.Equal(PlayState.Idle, s.State); Assert.Null(s.Url);
    }

    [Fact]
    public async Task Each_start_first_stops_what_was_playing()
    {
        var b = new FakeBackend(); var s = new PlaybackSession(b);
        var one = s.PlayAsync("a"); b.Starts["a"].SetResult(); await one;
        var two = s.PlayAsync("b");
        Assert.Equal(new[] { "stop", "start a", "stop", "start b" }, b.Log.ToArray());
        b.Starts["b"].SetResult(); await two;
    }

    [Fact]
    public async Task Changes_are_announced_so_the_screen_can_follow()
    {
        var b = new FakeBackend(); var s = new PlaybackSession(b); var seen = new List<PlayState>();
        s.Changed += () => seen.Add(s.State);
        var play = s.PlayAsync("a"); b.Starts["a"].SetResult(); await play; s.Stop();
        Assert.Equal(new[] { PlayState.Loading, PlayState.Playing, PlayState.Idle }, seen.ToArray());
    }
}
