using System.Runtime.InteropServices;
using System.Text;
using StreamSetu.Core;

namespace StreamSetu.App;

/// <summary>libmpv, loaded from libmpv-2.dll next to the program. The picture is drawn by mpv into a plain Win32 window (<c>wid</c>) that the player screen places over its video area.</summary>
internal static class MpvNative
{
    private const string Dll = "libmpv-2.dll";
    [DllImport(Dll)] public static extern IntPtr mpv_create();
    [DllImport(Dll)] public static extern int mpv_initialize(IntPtr ctx);
    [DllImport(Dll)] public static extern void mpv_terminate_destroy(IntPtr ctx);
    [DllImport(Dll, CharSet = CharSet.Ansi)] public static extern int mpv_set_option_string(IntPtr ctx, [MarshalAs(UnmanagedType.LPUTF8Str)] string name, [MarshalAs(UnmanagedType.LPUTF8Str)] string data);
    [DllImport(Dll, CharSet = CharSet.Ansi)] public static extern int mpv_set_property_string(IntPtr ctx, [MarshalAs(UnmanagedType.LPUTF8Str)] string name, [MarshalAs(UnmanagedType.LPUTF8Str)] string data);
    [DllImport(Dll)] public static extern IntPtr mpv_get_property_string(IntPtr ctx, [MarshalAs(UnmanagedType.LPUTF8Str)] string name);
    [DllImport(Dll)] public static extern void mpv_free(IntPtr data);
    [DllImport(Dll)] public static extern int mpv_command(IntPtr ctx, IntPtr[] args);
    [DllImport(Dll)] public static extern IntPtr mpv_wait_event(IntPtr ctx, double timeout);
    [DllImport(Dll)] public static extern IntPtr mpv_error_string(int error);

    [StructLayout(LayoutKind.Sequential)] public struct Event { public int Id; public int Error; public ulong ReplyUserData; public IntPtr Data; }
    [StructLayout(LayoutKind.Sequential)] public struct EndFile { public int Reason; public int Error; }

    public const int EventShutdown = 1, EventEndFile = 7, EventPlaybackRestart = 21;
    public const int EndFileError = 4;

    public static string Describe(int error) => Marshal.PtrToStringUTF8(mpv_error_string(error)) ?? $"error {error}";
}

/// <summary>Plays with libmpv. <see cref="PlaybackSession"/> decides which start counts; this class only starts, stops and answers questions about what is playing.</summary>
internal sealed class MpvBackend : IPlayerBackend, IDisposable
{
    private readonly IntPtr _videoWindow;
    private IntPtr _ctx;
    // Only one start waits for events at a time: two waiters on one player would take each other's events.
    private readonly SemaphoreSlim _waiter = new(1, 1);

    public MpvBackend(IntPtr videoWindow) { _videoWindow = videoWindow; }

    /// <summary>Set when encrypted DNS is on: turns an address into the pinned one before it is played.</summary>
    public Func<string, CancellationToken, Task<PinnedAddress>>? Pinner { get; set; }

    private static void Check(int result, string what) { if (result < 0) throw new InvalidOperationException($"{what}: {MpvNative.Describe(result)}"); }

    private void EnsureCreated()
    {
        if (_ctx != IntPtr.Zero) return;
        var ctx = MpvNative.mpv_create();
        if (ctx == IntPtr.Zero) throw new InvalidOperationException("The player could not be created.");
        try
        {
            Check(MpvNative.mpv_set_option_string(ctx, "wid", _videoWindow.ToInt64().ToString()), "window");
            MpvNative.mpv_set_option_string(ctx, "hwdec", "auto-safe");
            MpvNative.mpv_set_option_string(ctx, "vo", "gpu");
            MpvNative.mpv_set_option_string(ctx, "keep-open", "no");
            MpvNative.mpv_set_option_string(ctx, "input-default-bindings", "no");
            MpvNative.mpv_set_option_string(ctx, "osc", "no");
            MpvNative.mpv_set_option_string(ctx, "cache", "yes");
            MpvNative.mpv_set_option_string(ctx, "demuxer-max-bytes", "150MiB");
            MpvNative.mpv_set_option_string(ctx, "network-timeout", "20");
            MpvNative.mpv_set_option_string(ctx, "user-agent", "StreamSetu/0.1 (Windows)");
            Check(MpvNative.mpv_initialize(ctx), "start");
        }
        catch { MpvNative.mpv_terminate_destroy(ctx); throw; }
        _ctx = ctx;
    }

    private void Command(params string[] args)
    {
        var pointers = new IntPtr[args.Length + 1];
        try
        {
            for (int i = 0; i < args.Length; i++) pointers[i] = Marshal.StringToCoTaskMemUTF8(args[i]);
            Check(MpvNative.mpv_command(_ctx, pointers), args[0]);
        }
        finally { foreach (var p in pointers) if (p != IntPtr.Zero) Marshal.FreeCoTaskMem(p); }
    }

    public async Task StartAsync(string url, double startAt, CancellationToken ct)
    {
        EnsureCreated();
        // With encrypted DNS chosen, the name is looked up here and the player is given the address (the name travels in a Host header).
        if (Pinner is not null) { var pinned = await Pinner(url, ct).ConfigureAwait(false); url = pinned.Url; SetHttpHeaders(pinned.HostHeader is null ? null : "Host: " + pinned.HostHeader); }
        else SetHttpHeaders(null);
        MpvNative.mpv_set_property_string(_ctx, "start", startAt > 0 ? $"+{(int)startAt}" : "none");
        Command("loadfile", url, "replace");
        await _waiter.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await Task.Run(() =>
            {
                var deadline = Environment.TickCount64 + 30_000;
                while (true)
                {
                    ct.ThrowIfCancellationRequested();
                    if (Environment.TickCount64 > deadline) throw new InvalidOperationException("This stream took too long to start.");
                    var ptr = MpvNative.mpv_wait_event(_ctx, 0.2);
                    var ev = Marshal.PtrToStructure<MpvNative.Event>(ptr);
                    if (ev.Id == MpvNative.EventPlaybackRestart) return;
                    if (ev.Id == MpvNative.EventShutdown) throw new InvalidOperationException("The player closed.");
                    // Only a real error ends the wait with a failure. "Stopped" is what the previous stream reports when this one replaced it.
                    if (ev.Id == MpvNative.EventEndFile && ev.Data != IntPtr.Zero && Marshal.PtrToStructure<MpvNative.EndFile>(ev.Data) is { Reason: MpvNative.EndFileError } end)
                        throw new InvalidOperationException("This stream could not be played: " + MpvNative.Describe(end.Error));
                }
            }, ct).ConfigureAwait(false);
        }
        finally { _waiter.Release(); }
    }

    public void Stop() { if (_ctx != IntPtr.Zero) try { Command("stop"); } catch (InvalidOperationException) { } }

    // --- Controls and facts for the player screen ---
    public void SetPaused(bool paused) { if (_ctx != IntPtr.Zero) MpvNative.mpv_set_property_string(_ctx, "pause", paused ? "yes" : "no"); }
    public void SeekBy(double seconds) { if (_ctx != IntPtr.Zero) try { Command("seek", seconds.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture), "relative"); } catch (InvalidOperationException) { } }
    public void SeekTo(double seconds) { if (_ctx != IntPtr.Zero) try { Command("seek", seconds.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture), "absolute"); } catch (InvalidOperationException) { } }
    public void SetVolume(int percent) { if (_ctx != IntPtr.Zero) MpvNative.mpv_set_property_string(_ctx, "volume", Math.Clamp(percent, 0, 150).ToString()); }

    public sealed record Track(string Type, int Id, string Label, bool Selected);

    private string? Text(string name)
    {
        if (_ctx == IntPtr.Zero) return null;
        var p = MpvNative.mpv_get_property_string(_ctx, name);
        if (p == IntPtr.Zero) return null;
        try { return Marshal.PtrToStringUTF8(p); } finally { MpvNative.mpv_free(p); }
    }

    /// <summary>The audio and subtitle tracks of what is playing, read from mpv's track list.</summary>
    public List<Track> Tracks()
    {
        var list = new List<Track>();
        if (!int.TryParse(Text("track-list/count"), out var count)) return list;
        for (int i = 0; i < Math.Min(count, 200); i++)
        {
            var type = Text($"track-list/{i}/type"); if (type is not ("audio" or "sub")) continue;
            if (!int.TryParse(Text($"track-list/{i}/id"), out var id)) continue;
            var lang = Text($"track-list/{i}/lang"); var title = Text($"track-list/{i}/title"); var codec = Text($"track-list/{i}/codec");
            var label = string.Join(" · ", new[] { lang, title, codec }.Where(s => !string.IsNullOrWhiteSpace(s)));
            list.Add(new Track(type, id, label.Length > 0 ? label : $"Track {id}", Text($"track-list/{i}/selected") == "yes"));
        }
        return list;
    }

    /// <summary>The chapters of what is playing (for Skip intro, recap and credits).</summary>
    public List<Chapter> Chapters()
    {
        var list = new List<Chapter>();
        if (!int.TryParse(Text("chapter-list/count"), out var count)) return list;
        for (int i = 0; i < Math.Min(count, 500); i++)
            if (double.TryParse(Text($"chapter-list/{i}/time"), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var t))
                list.Add(new Chapter(Text($"chapter-list/{i}/title") ?? "", t));
        return list;
    }

    public void SetMuted(bool muted) => SetProperty("mute", muted ? "yes" : "no");
    /// <summary>Extra request headers for the next stream (used to carry the Host name when the address was pinned).</summary>
    public void SetHttpHeaders(string? fields) => SetProperty("http-header-fields", fields ?? "");

    public void SelectAudio(int id) => SetProperty("aid", id.ToString());
    public void SelectSubtitle(int? id) => SetProperty("sid", id?.ToString() ?? "no");
    public void SetSpeed(double speed) => SetProperty("speed", Math.Clamp(speed, 0.25, 4).ToString("0.##", System.Globalization.CultureInfo.InvariantCulture));
    /// <summary>Delay in seconds; positive shows the subtitle later.</summary>
    public void SetSubtitleDelay(double seconds) => SetProperty("sub-delay", seconds.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture));
    public void SetAudioDelay(double seconds) => SetProperty("audio-delay", seconds.ToString("0.###", System.Globalization.CultureInfo.InvariantCulture));
    /// <summary>brightness, contrast, saturation, gamma, each from -100 to 100.</summary>
    public void SetPicture(string name, int value) { if (name is "brightness" or "contrast" or "saturation" or "gamma") SetProperty(name, Math.Clamp(value, -100, 100).ToString()); }
    public void SetSubtitleStyle(int size, string colour, bool background)
    {
        SetProperty("sub-font-size", Math.Clamp(size, 20, 120).ToString());
        SetProperty("sub-color", colour);
        SetProperty("sub-back-color", background ? "#99000000" : "#00000000");
    }
    public void AddSubtitleFile(string path) { if (_ctx != IntPtr.Zero) try { Command("sub-add", path, "select"); } catch (InvalidOperationException) { } }
    public void Screenshot(string path) { if (_ctx != IntPtr.Zero) try { Command("screenshot-to-file", path, "window"); } catch (InvalidOperationException) { } }
    public void ToggleStats() { if (_ctx != IntPtr.Zero) try { Command("script-binding", "stats/display-stats-toggle"); } catch (InvalidOperationException) { } }
    public void SetProperty(string name, string value) { if (_ctx != IntPtr.Zero) MpvNative.mpv_set_property_string(_ctx, name, value); }

    /// <summary>True when nothing is playing any more: the stream ended, or failed after it had started.</summary>
    public bool IsIdle => Text("idle-active") == "yes";

    public double Position => Number("time-pos");
    public double Duration => Number("duration");
    private double Number(string name)
    {
        if (_ctx == IntPtr.Zero) return 0;
        var p = MpvNative.mpv_get_property_string(_ctx, name);
        if (p == IntPtr.Zero) return 0;
        try { return double.TryParse(Marshal.PtrToStringUTF8(p), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var v) ? v : 0; }
        finally { MpvNative.mpv_free(p); }
    }

    public void Dispose() { if (_ctx != IntPtr.Zero) { var c = _ctx; _ctx = IntPtr.Zero; MpvNative.mpv_terminate_destroy(c); } }
}

/// <summary>A black Win32 child window of the main window. mpv draws into it, and the player screen moves it over the video area.</summary>
internal static class VideoWindow
{
    private const int WsChild = 0x40000000, WsVisible = 0x10000000, WsClipSiblings = 0x04000000, WsClipChildren = 0x02000000, SsBlackRect = 0x4;
    private const uint SwpNoActivate = 0x0010, SwpShowWindow = 0x0040;
    private const int SwHide = 0, SwShow = 5;

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowExW(int exStyle, string cls, string name, int style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int w, int h, uint flags);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] private static extern bool DestroyWindow(IntPtr hWnd);

    public static IntPtr Create(IntPtr parent)
    {
        var h = CreateWindowExW(0, "Static", "", WsChild | WsClipSiblings | WsClipChildren | SsBlackRect, 0, 0, 1, 1, parent, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        if (h == IntPtr.Zero) throw new InvalidOperationException("The video window could not be created.");
        return h;
    }
    /// <summary>Whether the video window is showing. Dialogs hide it (it is a real window above the page) and bring it back after.</summary>
    public static bool Shown { get; private set; }
    public static void Place(IntPtr window, int x, int y, int w, int h) { Shown = true; SetWindowPos(window, IntPtr.Zero, x, y, Math.Max(w, 1), Math.Max(h, 1), SwpNoActivate | SwpShowWindow); }
    /// <summary>For Multi-View tiles: placed without touching the single player's shown/hidden flag.</summary>
    public static void PlaceTile(IntPtr window, int x, int y, int w, int h) => SetWindowPos(window, IntPtr.Zero, x, y, Math.Max(w, 1), Math.Max(h, 1), SwpNoActivate | SwpShowWindow);
    public static void Hide(IntPtr window) { Shown = false; ShowWindow(window, SwHide); }
    public static void Destroy(IntPtr window) => DestroyWindow(window);
}
