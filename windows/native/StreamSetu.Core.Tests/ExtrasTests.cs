using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using StreamSetu.Core;
using Xunit;

namespace StreamSetu.Core.Tests;

public sealed class ExtrasTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "streamsetu-test-" + Guid.NewGuid().ToString("N"));
    public void Dispose() { try { Directory.Delete(_dir, true); } catch (IOException) { } }
    private static readonly DateTimeOffset Now = new(2026, 11, 7, 20, 0, 0, TimeSpan.Zero);

    // ----- Logos -----

    private static readonly byte[] Png = { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4 };

    private sealed class FakeBytes(Func<string, byte[]> answer) : IBytesFetcher
    {
        public int Calls;
        public Task<byte[]> FetchBytesAsync(string url, long limit, CancellationToken ct = default) { Interlocked.Increment(ref Calls); return Task.FromResult(answer(url)); }
    }

    [Fact]
    public async Task A_logo_is_fetched_once_kept_on_disk_and_only_pictures_are_accepted()
    {
        var f = new FakeBytes(u => u.EndsWith("page") ? Encoding.UTF8.GetBytes("<html>not a picture</html>") : Png);
        var cache = new LogoCache(f, _dir);
        Assert.Equal(Png, await cache.GetAsync("http://h/logo.png"));
        Assert.Equal(Png, await new LogoCache(f, _dir).GetAsync("http://h/logo.png"));                // a new cache over the same folder: from disk
        Assert.Equal(1, f.Calls);
        Assert.Null(await cache.GetAsync("http://h/page"));                                           // a web page is not a picture
        Assert.Null(await cache.GetAsync("file:///etc/passwd")); Assert.Null(await cache.GetAsync("")); Assert.Null(await cache.GetAsync(null));
    }

    [Fact]
    public async Task A_damaged_cached_file_is_replaced_and_a_refused_address_just_means_no_logo()
    {
        var f = new FakeBytes(_ => Png); var cache = new LogoCache(f, _dir);
        Directory.CreateDirectory(_dir); File.WriteAllBytes(Path.Combine(_dir, LogoCache.FileNameFor("http://h/a.png")), new byte[] { 1, 2, 3 });
        Assert.Equal(Png, await cache.GetAsync("http://h/a.png"));
        var refused = new LogoCache(new ThrowingBytes(), Path.Combine(_dir, "other"));
        Assert.Null(await refused.GetAsync("http://192.168.1.1/x.png"));
    }

    private sealed class ThrowingBytes : IBytesFetcher { public Task<byte[]> FetchBytesAsync(string url, long limit, CancellationToken ct = default) => throw new FetchRefusedException(Refusal.Blocked, "no"); }

    [Fact]
    public async Task The_same_logo_asked_for_at_once_is_fetched_once_and_the_folder_stays_within_its_limit()
    {
        var gate = new TaskCompletionSource(); int calls = 0;
        var cache = new LogoCache(new Slow(async () => { Interlocked.Increment(ref calls); await gate.Task; return Png; }), _dir);
        var a = cache.GetAsync("http://h/x.png"); var b = cache.GetAsync("http://h/x.png"); gate.SetResult();
        await Task.WhenAll(a, b); Assert.Equal(1, calls);
        var small = new LogoCache(new FakeBytes(_ => Png), Path.Combine(_dir, "small"), maxBytes: Png.Length * 3);
        for (int i = 0; i < 10; i++) { await small.GetAsync($"http://h/{i}.png"); await Task.Delay(5); }
        Assert.True(Directory.GetFiles(Path.Combine(_dir, "small")).Length <= 3);
    }

    private sealed class Slow(Func<Task<byte[]>> make) : IBytesFetcher { public Task<byte[]> FetchBytesAsync(string url, long limit, CancellationToken ct = default) => make(); }

    // ----- Skip intro -----

    [Fact]
    public void Offers_to_skip_an_intro_a_recap_and_credits_from_the_chapter_names_and_jumps_to_the_next_chapter()
    {
        var chapters = new[] { new Chapter("Previously on", 0), new Chapter("Opening", 60), new Chapter("Episode", 150), new Chapter("End Credits", 2400) };
        Assert.Equal(new SkipOffer("Skip recap", 60), SkipMarkers.Offer(chapters, 10, 2500));
        Assert.Equal(new SkipOffer("Skip intro", 150), SkipMarkers.Offer(chapters, 100, 2500));
        Assert.Null(SkipMarkers.Offer(chapters, 600, 2500));
        Assert.Equal(new SkipOffer("Skip credits", 2500), SkipMarkers.Offer(chapters, 2420, 2500));
        Assert.Null(SkipMarkers.Offer(chapters, 2499, 2500));                                        // the last second is not worth a button
        Assert.Null(SkipMarkers.Offer(new[] { new Chapter("Intro", 0) }, 10, 2500));                 // a single chapter is the whole film, not an intro
        Assert.Null(SkipMarkers.Offer(Array.Empty<Chapter>(), 10, 100));
    }

    // ----- Reminders -----

    [Fact]
    public void A_reminder_is_due_from_its_lead_time_until_five_minutes_after_the_start_and_only_once()
    {
        var store = new ReminderStore(new LocalStore(_dir));
        var start = Now.AddMinutes(30);
        Assert.True(store.Add("BBC One", "News", start, 5, Now)); Assert.False(store.Add("BBC One", "News", start, 5, Now));          // not twice
        Assert.False(store.Add("BBC One", "Past", Now.AddMinutes(-1), 5, Now));
        Assert.Empty(store.Due(Now.AddMinutes(20)));
        var due = Assert.Single(store.Due(Now.AddMinutes(26))); Assert.Equal("News", due.Title);
        store.MarkFired(due.Id); Assert.Empty(store.Due(Now.AddMinutes(27)));
        Assert.True(store.Add("ITV", "Late", Now.AddMinutes(10), 0, Now));
        Assert.Empty(store.Due(Now.AddMinutes(16)));                                                  // five minutes after the start, it is too old to announce
        Assert.Single(store.Due(Now.AddMinutes(12)));
        store.Prune(Now.AddHours(3)); Assert.Empty(store.All());
    }

    // ----- Recording -----

    [Fact]
    public void Recordings_are_scheduled_a_little_early_and_late_and_say_when_they_clash()
    {
        var store = new RecordingStore(new LocalStore(_dir));
        var (a, w1) = store.Add("News", "http://h/live/1.ts", Now.AddHours(1), Now.AddHours(2), Now);
        Assert.Equal(Now.AddHours(1).AddMinutes(-1), a.Start); Assert.Equal(Now.AddHours(2).AddMinutes(2), a.Stop); Assert.Null(w1);
        var (_, w2) = store.Add("Match", "http://h/live/2.ts", Now.AddHours(1.5), Now.AddHours(3), Now);
        Assert.Contains("overlaps", w2); Assert.Contains("one stream at a time", w2);
        Assert.Throws<ArgumentException>(() => store.Add("x", "http://h/x", Now.AddHours(2), Now.AddHours(1), Now));
        Assert.Throws<ArgumentException>(() => store.Add("x", "http://h/x", Now.AddHours(-3), Now.AddHours(-2), Now));
        Assert.Throws<ArgumentException>(() => store.Add("x", "http://h/x", Now, Now.AddHours(13), Now));
        Assert.Throws<ArgumentException>(() => store.Add("x", "file:///c:/x", Now.AddHours(1), Now.AddHours(2), Now));
    }

    [Fact]
    public void Due_recordings_are_found_and_missed_ones_are_marked_not_left_scheduled()
    {
        var store = new RecordingStore(new LocalStore(_dir));
        var (r, _) = store.Add("News", "http://h/1.ts", Now.AddHours(1), Now.AddHours(2), Now);
        Assert.Empty(store.Due(Now)); Assert.Single(store.Due(Now.AddHours(1)));
        store.Update(r with { Status = RecordingStatus.Recording });
        store.Add("Later", "http://h/2.ts", Now.AddHours(1), Now.AddHours(2), Now);
        store.SettleMissed(Now.AddHours(5));
        Assert.All(store.All(), x => Assert.Equal(RecordingStatus.Failed, x.Status));
        Assert.Contains("closed during", store.All().First(x => x.Id == r.Id).Message);
    }

    [Fact]
    public void Recording_file_names_cannot_leave_the_folder_or_use_names_Windows_refuses()
    {
        var t = new DateTimeOffset(2026, 11, 7, 20, 0, 0, TimeSpan.Zero);
        foreach (var bad in new[] { "..\\..\\evil", "a/b/c", "CON", "nul", "x:y*z?\"<>|", "   ", "....", new string('a', 300) })
        {
            var name = Recorder.SafeName(bad, t);
            Assert.DoesNotContain(name, new[] { "\\", "/" }.Where(name.Contains)); Assert.True(name.Length < 120, name);
            Assert.EndsWith(".ts", name); Assert.Equal(name, Path.GetFileName(name)); Assert.DoesNotMatch(@"^(con|nul)\b", name.ToLowerInvariant());
        }
    }

    private static (HttpListener Listener, string Url, CancellationTokenSource Stop) Streamer(Func<HttpListenerResponse, CancellationToken, Task> serve)
    {
        var probe = new TcpListener(IPAddress.Loopback, 0); probe.Start(); var port = ((IPEndPoint)probe.LocalEndpoint).Port; probe.Stop();
        var l = new HttpListener(); l.Prefixes.Add($"http://127.0.0.1:{port}/"); l.Start();
        var stop = new CancellationTokenSource();
        _ = Task.Run(async () => { while (!stop.IsCancellationRequested) { HttpListenerContext c; try { c = await l.GetContextAsync(); } catch { return; } _ = Task.Run(async () => { try { await serve(c.Response, stop.Token); } catch { } finally { try { c.Response.Close(); } catch { } } }); } });
        return (l, $"http://127.0.0.1:{port}/live.ts", stop);
    }

    [Fact]
    public async Task A_recording_copies_the_stream_until_its_end_time_and_keeps_what_it_saved()
    {
        var (listener, url, stop) = Streamer(async (r, ct) => { var chunk = new byte[10_000]; while (!ct.IsCancellationRequested) { await r.OutputStream.WriteAsync(chunk, ct); await r.OutputStream.FlushAsync(ct); await Task.Delay(20, ct); } });
        try
        {
            var allow = new HostAllowList(); allow.Add("127.0.0.1"); using var http = new SafeHttp(allow, "test");
            var rec = new Recording("r1", "Test: Show?", url, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow.AddSeconds(1.2));
            var done = await new Recorder(http, _dir, minFreeBytes: 1).RunAsync(rec, default);
            Assert.Equal(RecordingStatus.Done, done.Status); Assert.True(done.Bytes > 10_000); Assert.True(File.Exists(done.Path)); Assert.Equal(done.Bytes, new FileInfo(done.Path!).Length);
            Assert.Equal(_dir, Path.GetDirectoryName(done.Path));
            var second = await new Recorder(http, _dir, minFreeBytes: 1).RunAsync(rec with { Stop = DateTimeOffset.UtcNow.AddSeconds(0.6) }, default);
            Assert.NotEqual(done.Path, second.Path);                                                  // an existing file is never overwritten
        }
        finally { stop.Cancel(); listener.Close(); }
    }

    [Fact]
    public async Task A_recording_that_the_person_stops_is_cancelled_with_what_was_saved_and_a_silent_stream_is_a_failure()
    {
        var (listener, url, stop) = Streamer(async (r, ct) => { var chunk = new byte[5000]; for (int i = 0; i < 200 && !ct.IsCancellationRequested; i++) { await r.OutputStream.WriteAsync(chunk, ct); await r.OutputStream.FlushAsync(ct); await Task.Delay(20, ct); } });
        var (listener2, url2, stop2) = Streamer((r, ct) => Task.Delay(3000, ct));
        try
        {
            var allow = new HostAllowList(); allow.Add("127.0.0.1"); using var http = new SafeHttp(allow, "test");
            using var cts = new CancellationTokenSource(); cts.CancelAfter(500);
            var stopped = await new Recorder(http, _dir, minFreeBytes: 1).RunAsync(new Recording("a", "Stopped", url, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow.AddMinutes(5)), cts.Token);
            Assert.Equal(RecordingStatus.Cancelled, stopped.Status); Assert.True(stopped.Bytes > 0);
            var silent = await new Recorder(http, _dir, minFreeBytes: 1).RunAsync(new Recording("b", "Silent", url2, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow.AddSeconds(1)), default);
            Assert.Equal(RecordingStatus.Failed, silent.Status);
            var passed = await new Recorder(http, _dir, minFreeBytes: 1).RunAsync(new Recording("c", "Past", url, DateTimeOffset.UtcNow.AddHours(-2), DateTimeOffset.UtcNow.AddHours(-1)), default);
            Assert.Equal(RecordingStatus.Failed, passed.Status);
            var local = await new Recorder(new SafeHttp(new HostAllowList(), "t"), _dir, minFreeBytes: 1).RunAsync(new Recording("d", "Blocked", url, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow.AddSeconds(2)), default);
            Assert.Equal(RecordingStatus.Failed, local.Status); Assert.Contains("computer or network", local.Message);          // recording obeys the same address rules
            var disk = await new Recorder(http, _dir, minFreeBytes: long.MaxValue).RunAsync(new Recording("e", "Full", url, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow.AddSeconds(2)), default);
            Assert.Contains("free on the disk", disk.Message);
        }
        finally { stop.Cancel(); listener.Close(); stop2.Cancel(); listener2.Close(); }
    }

    // ----- Multi-View -----

    [Theory]
    [InlineData(1)] [InlineData(2)] [InlineData(3)] [InlineData(4)] [InlineData(9)]
    public void Tiles_fit_inside_the_area_and_never_overlap(int count)
    {
        var tiles = MultiViewLayout.Tiles(count, 1280, 720);
        Assert.Equal(Math.Min(count, 4), tiles.Count);
        foreach (var t in tiles) { Assert.True(t.X >= 0 && t.Y >= 0 && t.X + t.Width <= 1280 && t.Y + t.Height <= 720 && t.Width > 0 && t.Height > 0, t.ToString()); }
        for (int i = 0; i < tiles.Count; i++) for (int j = i + 1; j < tiles.Count; j++)
        { var a = tiles[i]; var b = tiles[j]; Assert.False(a.X < b.X + b.Width && b.X < a.X + a.Width && a.Y < b.Y + b.Height && b.Y < a.Y + a.Height, $"{a} overlaps {b}"); }
    }

    [Fact]
    public void Tile_layout_handles_empty_and_tiny_areas()
    {
        Assert.Empty(MultiViewLayout.Tiles(0, 100, 100)); Assert.Empty(MultiViewLayout.Tiles(2, 0, 100)); Assert.Equal(new Tile(0, 0, 640, 720), MultiViewLayout.Tiles(2, 1284, 720)[0]);
        Assert.All(MultiViewLayout.Tiles(4, 3, 3), t => Assert.True(t.Width >= 1 && t.Height >= 1));
    }

    // ----- Updates -----

    private static string Release(string name, string url, string body) => System.Text.Json.JsonSerializer.Serialize(new { tag_name = "x", body, assets = new[] { new { name, browser_download_url = url } } });
    private const string Prefix = "https://github.com/lokeshreddyveer/streamsetu/releases/download/2026.11.07/";

    [Fact]
    public void An_update_is_found_only_when_it_is_newer_ours_and_has_a_checksum()
    {
        var sha = new string('a', 64);
        var good = Release("StreamSetu-Setup-1.2.0.exe", Prefix + "StreamSetu-Setup-1.2.0.exe", $"Notes\n`StreamSetu-Setup-1.2.0.exe`  {sha}\n");
        var info = Updates.Parse(good, new Version(1, 1, 0))!;
        Assert.Equal(new Version(1, 2, 0), info.Version); Assert.Equal(sha, info.Sha256);
        Assert.Null(Updates.Parse(good, new Version(1, 2, 0))); Assert.Null(Updates.Parse(good, new Version(2, 0)));
        Assert.Null(Updates.Parse(Release("StreamSetu-Setup-1.2.0.exe", Prefix + "StreamSetu-Setup-1.2.0.exe", "no checksum here"), new Version(1, 0)));
        Assert.Null(Updates.Parse("""{"tag_name":"x"}""", new Version(1, 0))); Assert.Throws<InvalidOperationException>(() => Updates.Parse("<html>", new Version(1, 0)));
    }

    [Theory]
    [InlineData("StreamSetu-Setup-1.2.0.exe", "https://evil.example/releases/download/x/StreamSetu-Setup-1.2.0.exe")]
    [InlineData("StreamSetu-Setup-1.2.0.exe", "https://github.com/lokeshreddyveer/streamsetu/releases/download/x/Other.exe")]
    [InlineData("StreamSetu-Setup-1.2.0.exe", "https://github.com/lokeshreddyveer/streamsetu/releases/download/../../evil/StreamSetu-Setup-1.2.0.exe")]
    [InlineData("StreamSetu-Setup-1.2.0.exe", "https://github.com/lokeshreddyveer/streamsetu/releases/download/x/StreamSetu-Setup-1.2.0.exe?redirect=evil")]
    [InlineData("..\\StreamSetu-Setup-1.2.0.exe", "https://github.com/lokeshreddyveer/streamsetu/releases/download/x/..\\StreamSetu-Setup-1.2.0.exe")]
    [InlineData("StreamSetu-Setup-1.2.0.exe.exe", "https://github.com/lokeshreddyveer/streamsetu/releases/download/x/StreamSetu-Setup-1.2.0.exe.exe")]
    [InlineData("StreamSetu-Android-9.9.9.apk", "https://github.com/lokeshreddyveer/streamsetu/releases/download/x/StreamSetu-Android-9.9.9.apk")]
    public void A_release_page_that_points_the_updater_anywhere_else_is_ignored(string name, string url)
        => Assert.Null(Updates.Parse(Release(name, url, $"`{name}`  {new string('a', 64)}"), new Version(1, 0)));

    [Fact]
    public void A_download_is_kept_only_when_it_matches_its_checksum()
    {
        var file = Encoding.UTF8.GetBytes("installer bytes");
        var sha = Convert.ToHexString(SHA256.HashData(file)).ToLowerInvariant();
        Assert.True(Updates.Matches(file, sha)); Assert.True(Updates.Matches(file, sha.ToUpperInvariant())); Assert.False(Updates.Matches(file, new string('0', 64)));
        Assert.False(Updates.Matches(Encoding.UTF8.GetBytes("tampered"), sha));
    }

    // ----- Encrypted DNS for the player -----

    private sealed class Fixed(params string[] ips) : IHostResolver { public Task<IPAddress[]> ResolveAsync(string host, CancellationToken ct) => Task.FromResult(ips.Select(IPAddress.Parse).ToArray()); }

    [Fact]
    public async Task An_http_address_is_pinned_to_the_address_found_with_the_name_kept_in_a_Host_header()
    {
        var allow = new HostAllowList();
        var pinned = await Pinning.PinAsync("http://provider.example:8080/live/u/p/1.ts?x=1", new Fixed("93.184.216.34"), allow);
        Assert.Equal("http://93.184.216.34:8080/live/u/p/1.ts?x=1", pinned.Url); Assert.Equal("provider.example:8080", pinned.HostHeader);
        Assert.Equal("provider.example", (await Pinning.PinAsync("http://provider.example/a", new Fixed("93.184.216.34"), allow)).HostHeader);
        Assert.Contains("[2606:4700::1111]", (await Pinning.PinAsync("http://p.example/a", new Fixed("2606:4700::1111"), allow)).Url);
    }

    [Fact]
    public async Task Pinning_leaves_https_numeric_and_unsafe_answers_alone()
    {
        var allow = new HostAllowList();
        foreach (var url in new[] { "https://provider.example/a", "http://93.184.216.34/a", "http://[::1]/a", "file:///c:/x.mp4", "not a url" })
        { var p = await Pinning.PinAsync(url, new Fixed("93.184.216.34"), allow); Assert.Equal(url, p.Url); Assert.Null(p.HostHeader); }
        var local = await Pinning.PinAsync("http://rebind.example/a", new Fixed("192.168.1.1"), allow);       // a name answered with a local address is not pinned
        Assert.Equal("http://rebind.example/a", local.Url);
        allow.Add("nas.local");
        Assert.Equal("http://192.168.1.50/a", (await Pinning.PinAsync("http://nas.local/a", new Fixed("192.168.1.50"), allow)).Url);              // unless the host is in a connection
    }
}
