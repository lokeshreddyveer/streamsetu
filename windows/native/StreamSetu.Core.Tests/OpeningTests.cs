using System.Text.Json;
using StreamSetu.Core;
using Xunit;

namespace StreamSetu.Core.Tests;

public class OpeningTests
{
    private static JsonElement Spec()
    {
        var d = new DirectoryInfo(AppContext.BaseDirectory);
        while (d is not null)
        {
            var p = Path.Combine(d.FullName, "motion", "specification", "opening-motion.json");
            if (File.Exists(p)) return JsonDocument.Parse(File.ReadAllText(p)).RootElement;
            d = d.Parent;
        }
        throw new FileNotFoundException("motion/specification/opening-motion.json");
    }

    private static string Name(OpeningVariant v) => v switch { OpeningVariant.FirstInstall => "firstInstall", OpeningVariant.Standard => "standard", _ => "reducedMotion" };

    [Theory]
    [InlineData(OpeningVariant.FirstInstall, 7500)]
    [InlineData(OpeningVariant.Standard, 2800)]
    [InlineData(OpeningVariant.ReducedMotion, 1400)]
    public void DurationsAndScenesMatchTheSpecification(OpeningVariant v, int ms)
    {
        var spec = Spec().GetProperty("variants").GetProperty(Name(v));
        Assert.Equal(ms, spec.GetProperty("durationMs").GetInt32());
        Assert.Equal(ms, Opening.DurationMs(v));
        var scenes = spec.GetProperty("scenes").EnumerateArray().Select(s => new OpeningScene(s.GetProperty("name").GetString()!, s.GetProperty("startMs").GetInt32(), s.GetProperty("endMs").GetInt32())).ToList();
        Assert.Equal(scenes, Opening.Scenes(v));
        Assert.Equal(ms, Opening.Scenes(v)[^1].EndMs);
    }

    private static Span Pair(JsonElement e) => new(e[0].GetInt32(), e[1].GetInt32());

    [Fact]
    public void KeyframesMatchTheSpecification()
    {
        var root = Spec();
        var first = root.GetProperty("keyframesMsFirstInstall"); var k1 = Opening.Keys(OpeningVariant.FirstInstall)!;
        Assert.Equal(first.GetProperty("dotAppears").GetInt32(), k1.DotAppears);
        Assert.Equal(Pair(first.GetProperty("lightSweep")), k1.LightSweep);
        Assert.Equal(Pair(first.GetProperty("antennaTwitch")), k1.AntennaTwitch);
        Assert.Equal(Pair(first.GetProperty("snow")), k1.Snow);
        Assert.Equal(Pair(first.GetProperty("screenWarm")), k1.ScreenWarm);
        Assert.Equal(Pair(first.GetProperty("ribbonRearDraw")), k1.RibbonRearDraw);
        Assert.Equal(Pair(first.GetProperty("ribbonFrontDraw")), k1.RibbonFrontDraw);
        Assert.Equal(Pair(first.GetProperty("dotToPlay")), k1.DotToPlay);
        Assert.Equal(Pair(first.GetProperty("heroPressIn")), k1.HeroPressIn);
        Assert.Equal(first.GetProperty("glint").GetInt32(), k1.Glint);
        Assert.Equal(Pair(first.GetProperty("ribbonSheen")), k1.RibbonSheen);
        Assert.Equal(Pair(first.GetProperty("wordmark")), k1.Wordmark);
        Assert.Equal(Pair(first.GetProperty("tagline")), k1.Tagline);
        Assert.Equal(Pair(first.GetProperty("matchCutExpand")), k1.MatchCutExpand);

        var std = root.GetProperty("keyframesMs"); var k2 = Opening.Keys(OpeningVariant.Standard)!;
        Assert.Equal(std.GetProperty("dotAppears").GetInt32(), k2.DotAppears);
        Assert.Equal(new Span(std.GetProperty("lightSweepStart").GetInt32(), std.GetProperty("lightSweepEnd").GetInt32()), k2.LightSweep);
        Assert.Equal(Pair(std.GetProperty("antennaTwitch")), k2.AntennaTwitch);
        Assert.Equal(1000, (k2.Snow.From + k2.Snow.To) / 2);                                       // the specification gives the peak
        Assert.Equal(Pair(std.GetProperty("screenWarm")), k2.ScreenWarm);
        Assert.Equal(Pair(std.GetProperty("ribbonRearDraw")), k2.RibbonRearDraw);
        Assert.Equal(Pair(std.GetProperty("ribbonFrontDraw")), k2.RibbonFrontDraw);
        Assert.Equal(Pair(std.GetProperty("dotToPlay")), k2.DotToPlay);
        Assert.Equal(Pair(std.GetProperty("heroPressIn")), k2.HeroPressIn);
        Assert.Equal(Pair(std.GetProperty("wordmark")), k2.Wordmark);
        Assert.Equal(Pair(std.GetProperty("tagline")), k2.Tagline);
        Assert.Equal(Pair(std.GetProperty("matchCutExpand")), k2.MatchCutExpand);
    }

    [Fact]
    public void ItCannotBeSkippedAndTheSpecificationSaysSo()
    {
        Assert.False(Opening.Skippable);
        Assert.Contains("cannot be skipped", Spec().GetProperty("interaction").GetString());
    }

    [Fact]
    public void LaunchPlanPicksTheVariant()
    {
        Assert.Equal(OpeningVariant.FirstInstall, Opening.Decide(introDone: false, hasConnections: false, reducedMotion: false, suppressed: false));
        Assert.Equal(OpeningVariant.Standard, Opening.Decide(true, false, false, false));
        Assert.Equal(OpeningVariant.Standard, Opening.Decide(false, true, false, false));
        Assert.Equal(OpeningVariant.ReducedMotion, Opening.Decide(false, false, true, false));
        Assert.Null(Opening.Decide(false, false, false, true));
    }

    [Theory]
    [InlineData(OpeningVariant.FirstInstall)]
    [InlineData(OpeningVariant.Standard)]
    public void FramesStartDarkEndInTheLockupAndNeverLeaveRange(OpeningVariant v)
    {
        var start = Opening.Frame(v, 0);
        Assert.Equal(0, start.Dot); Assert.Equal(0, start.Play); Assert.Equal(0, start.Wordmark); Assert.Equal(0, start.RibbonFront);
        var end = Opening.Frame(v, Opening.DurationMs(v));
        Assert.Equal(1, end.Play); Assert.Equal(1, end.Wordmark); Assert.Equal(1, end.Tagline); Assert.Equal(1, end.MatchCut, 6);
        for (var ms = 0; ms <= Opening.DurationMs(v); ms += 7)
        {
            var f = Opening.Frame(v, ms);
            foreach (var x in new[] { f.SetLight, f.Dot, f.Warm, f.RibbonRear, f.RibbonFront, f.Play, f.Press, f.Glint, f.Wordmark, f.Tagline, f.MatchCut, f.Push, f.Snow }) Assert.InRange(x, 0, 1.0000001);
            Assert.InRange(Math.Abs(f.TwitchLeft), 0, 6); Assert.InRange(Math.Abs(f.TwitchRight), 0, 6);          // the specification's twitch limit
        }
        Assert.Equal(Opening.Frame(v, 1234), Opening.Frame(v, 1234));                                          // pure: the same time, the same frame
    }

    [Fact]
    public void ReducedMotionShowsTheStillLockup()
    {
        Assert.Equal(OpeningFrame.Lockup, Opening.Frame(OpeningVariant.ReducedMotion, 300));
        Assert.Equal("fade", Opening.Scene(OpeningVariant.ReducedMotion, 1100));
        Assert.Null(Opening.Scene(OpeningVariant.Standard, 2800));
    }

    [Fact]
    public void ThePlayButtonPressesInDuringTheHeroBeat()
    {
        var k = Opening.Keys(OpeningVariant.FirstInstall)!;
        Assert.True(Opening.Frame(OpeningVariant.FirstInstall, (k.HeroPressIn.From + k.HeroPressIn.To) / 2).Press > 0.5);
        Assert.Equal(0, Opening.Frame(OpeningVariant.FirstInstall, k.HeroPressIn.To + 100).Press);
    }
}
