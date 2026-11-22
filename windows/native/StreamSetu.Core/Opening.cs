namespace StreamSetu.Core;

/// <summary>The opening, "Tune In": the retro television is tuned in, the ribbon binds it, the dot becomes the play button, the name arrives. The first launch of a new install plays the full 7.5 s story,
/// every other launch the 2.8 s cut. It cannot be skipped and ends on elapsed time alone. This is the timeline only: what is on screen at a moment, worked out from the time alone, so any frame can be drawn or tested.
/// The tables match motion/specification/opening-motion.json (a test fails when they drift apart); the Swift timeline is the reference.</summary>
public enum OpeningVariant { FirstInstall, Standard, ReducedMotion }

public readonly record struct Span(int From, int To);

public sealed record OpeningKeyframes(int DotAppears, Span LightSweep, Span AntennaTwitch, Span Snow, Span ScreenWarm, Span RibbonRearDraw, Span RibbonFrontDraw, Span DotToPlay, Span HeroPressIn,
    int Glint, Span RibbonSheen, Span Wordmark, Span Tagline, Span MatchCutExpand, Span? EaseBack);

public sealed record OpeningScene(string Id, int StartMs, int EndMs);

/// <summary>Everything the screen needs for one frame. Values are 0..1 unless said otherwise.</summary>
public sealed record OpeningFrame
{
    public double SetLight, Dot, Warm, RibbonRear, RibbonFront, Play, Press, Glint, Wordmark, Tagline, MatchCut, Push, EaseBack, Snow;
    public double Sweep = -1, Sheen = -1;
    /// <summary>The antennas' tuning twitch in degrees, settling to 0.</summary>
    public double TwitchLeft, TwitchRight;

    public static OpeningFrame Lockup => new() { SetLight = 1, Warm = 1, RibbonRear = 1, RibbonFront = 1, Play = 1, Wordmark = 1, Tagline = 1, Push = 1 };
}

public static class Opening
{
    /// <summary>Never skippable: no tap, key or Back handling. It ends on elapsed time, with a hard fallback so it can never stay on screen.</summary>
    public const bool Skippable = false;
    public const int FallbackMarginMs = 1500;

    public static int DurationMs(OpeningVariant v) => v switch { OpeningVariant.FirstInstall => 7500, OpeningVariant.Standard => 2800, _ => 1400 };

    public static IReadOnlyList<OpeningScene> Scenes(OpeningVariant v)
    {
        static OpeningScene S(string id, int a, int b) => new(id, a, b);
        return v switch
        {
            OpeningVariant.FirstInstall => new[] { S("dark", 0, 500), S("glowDot", 500, 1500), S("sweepTwitch", 1500, 2500), S("warm", 2500, 3500), S("anticipation", 3500, 4500), S("hero", 4500, 5000), S("sheen", 5000, 5500), S("wordmark", 5500, 6200), S("tagline", 6200, 7000), S("matchCut", 7000, 7500) },
            OpeningVariant.Standard => new[] { S("dark", 0, 200), S("glowDot", 200, 700), S("sweepTwitch", 700, 1200), S("warmWrap", 1200, 1900), S("hero", 1900, 2150), S("lockup", 2150, 2500), S("hold", 2500, 2650), S("matchCut", 2650, 2800) },
            _ => new[] { S("still", 0, 1000), S("fade", 1000, 1400) },
        };
    }

    public static OpeningKeyframes? Keys(OpeningVariant v) => v switch
    {
        OpeningVariant.FirstInstall => new(500, new(1500, 2300), new(1700, 2200), new(1500, 2500), new(2500, 3500), new(2500, 3500), new(3500, 4500), new(3500, 4500), new(4500, 4750), 4750,
            new(5000, 5500), new(5500, 6200), new(6200, 7000), new(7000, 7500), new(3500, 4500)),
        // The specification gives the snow as its peak (1000 ms); it rises and falls over 250 ms either side.
        OpeningVariant.Standard => new(200, new(700, 1150), new(850, 1100), new(750, 1250), new(1100, 1700), new(1150, 1600), new(1400, 1850), new(1500, 1900), new(1900, 2050), 2000,
            new(2000, 2400), new(2150, 2400), new(2250, 2500), new(2650, 2800), null),
        _ => null,
    };

    /// <summary>Where the story ends and the exit begins.</summary>
    public static int HoldMs(OpeningVariant v) => Scenes(v)[^1].StartMs;

    public static double Clamp(double x) => Math.Min(1, Math.Max(0, x));
    public static double EaseOut(double x) { var t = Clamp(x); return 1 - Math.Pow(1 - t, 3); }
    public static double CubicInOut(double x) { var t = Clamp(x); return t < 0.5 ? 4 * t * t * t : 1 - Math.Pow(-2 * t + 2, 3) / 2; }
    public static double SlowInOut(double x) { var t = Clamp(x); return 0.5 - 0.5 * Math.Cos(Math.PI * t); }

    private static double P(double ms, Span r) => Clamp((ms - r.From) / Math.Max(1, r.To - r.From));
    private static double Inside(double ms, Span r) => ms >= r.From && ms <= r.To ? P(ms, r) : -1;

    /// <summary>A tuning twitch: a quick turn that overshoots a little and settles.</summary>
    public static double Twitch(double q, double amplitude, double phase)
        => q > 0 && q < 1 ? amplitude * Math.Exp(-3.2 * q) * Math.Sin(2 * Math.PI * (2.1 * q + phase)) * (1 - q) : 0;

    /// <summary>The frame at <paramref name="ms"/> from the start. Pure: the same time always gives the same frame.</summary>
    public static OpeningFrame Frame(OpeningVariant v, double ms)
    {
        if (Keys(v) is not { } k) return OpeningFrame.Lockup;
        if (ms >= HoldMs(v)) { var l = OpeningFrame.Lockup; l.MatchCut = CubicInOut(P(ms, k.MatchCutExpand)); return l; }
        var silhouette = EaseOut(P(ms, new Span(k.DotAppears, k.LightSweep.From)));
        var warm = SlowInOut(P(ms, k.ScreenWarm));
        var front = CubicInOut(P(ms, k.RibbonFrontDraw));
        var play = EaseOut(P(ms, k.DotToPlay));
        var twitchP = Inside(ms, k.AntennaTwitch);
        var snowP = P(ms, k.Snow);
        var glintSpan = Math.Max(150, k.HeroPressIn.To - k.HeroPressIn.From);
        var glintP = Inside(ms, new Span(k.Glint - glintSpan / 2, k.Glint + glintSpan / 2));
        var pressP = Inside(ms, k.HeroPressIn);
        var sweepP = Inside(ms, k.LightSweep);
        return new OpeningFrame
        {
            SetLight = Math.Min(1, 0.22 * silhouette + 0.33 * warm + 0.45 * front),
            Dot = EaseOut(P(ms, new Span(k.DotAppears, k.DotAppears + 250))) * (1 - play),
            Sweep = sweepP < 0 ? -1 : CubicInOut(sweepP),
            TwitchLeft = Twitch(Math.Max(0, twitchP), -5.5, 0),
            TwitchRight = Twitch(Math.Max(0, twitchP), 5, 0.08),
            Snow = snowP > 0 && snowP < 1 ? Math.Sin(Math.PI * snowP) : 0,
            Warm = warm,
            RibbonRear = CubicInOut(P(ms, k.RibbonRearDraw)),
            RibbonFront = front,
            Play = play,
            Press = pressP > 0 && pressP < 1 ? Math.Sin(Math.PI * EaseOut(pressP)) : 0,
            Glint = glintP > 0 && glintP < 1 ? Math.Sin(Math.PI * glintP) : 0,
            Sheen = Inside(ms, k.RibbonSheen),
            Wordmark = EaseOut(P(ms, k.Wordmark)),
            Tagline = EaseOut(P(ms, k.Tagline)),
            Push = SlowInOut(P(ms, new Span(k.DotAppears, HoldMs(v)))),
            EaseBack = k.EaseBack is { } eb ? Math.Sin(Math.PI * P(ms, eb)) : 0,
        };
    }

    public static string? Scene(OpeningVariant v, int ms) => Scenes(v).FirstOrDefault(s => ms >= s.StartMs && ms < s.EndMs)?.Id;

    /// <summary>Which opening this launch plays, or null for none. The first launch of a new install (no connection ever added, the opening never seen) gets the full story; every other launch the short cut;
    /// Reduce Motion (animations off in Windows) shows the still. <paramref name="suppressed"/> is a test run (SS_SKIP_INTRO=1).</summary>
    public static OpeningVariant? Decide(bool introDone, bool hasConnections, bool reducedMotion, bool suppressed)
    {
        if (suppressed) return null;
        if (reducedMotion) return OpeningVariant.ReducedMotion;
        return !introDone && !hasConnections ? OpeningVariant.FirstInstall : OpeningVariant.Standard;
    }
}
