using StreamSetu.Core;
using Xunit;

namespace StreamSetu.Core.Tests;

public class GuideTests
{
    private const string Sample = """
<?xml version="1.0" encoding="UTF-8"?>
<tv>
  <channel id="bbc1"><display-name>BBC One</display-name></channel>
  <programme start="20261107180000 +0000" stop="20261107190000 +0000" channel="bbc1"><title lang="en">News at Six</title><desc>The headlines.</desc></programme>
  <programme start="20261107190000 +0000" stop="20261107200000 +0000" channel="bbc1"><title>Football Tonight</title></programme>
  <programme start="20261107200000 +0100" stop="20261107210000 +0100" channel="itv"><title>Drama</title><desc>A cricket story</desc></programme>
  <programme start="bad" stop="20261107210000" channel="itv"><title>Broken time</title></programme>
  <programme start="20261107210000" stop="20261107200000" channel="itv"><title>Ends before it starts</title></programme>
  <programme start="20261107210000" stop="20261107220000" channel="itv"/>
</tv>
""";

    private static DateTimeOffset At(int h, int m = 0) => new(2026, 11, 7, h, m, 0, TimeSpan.Zero);

    [Fact]
    public void Reads_programmes_and_skips_the_ones_that_make_no_sense()
    {
        var list = Xmltv.Parse(Sample);
        Assert.Equal(new[] { "News at Six", "Football Tonight", "Drama" }, list.Select(p => p.Title).ToArray());
        Assert.Equal("The headlines.", list[0].Description); Assert.Null(list[1].Description);
    }

    [Fact]
    public void Times_keep_their_offset()
    {
        Assert.Equal(At(18), Xmltv.ParseTime("20261107180000 +0000"));
        Assert.Equal(At(19), Xmltv.ParseTime("20261107200000 +0100"));
        Assert.Equal(At(18), Xmltv.ParseTime("20261107180000"));
        Assert.Equal(At(18, 30), Xmltv.ParseTime("202611071830"));
        Assert.Equal(At(23), Xmltv.ParseTime("20261107180000 -0500"));
        Assert.Null(Xmltv.ParseTime("")); Assert.Null(Xmltv.ParseTime("yesterday")); Assert.Null(Xmltv.ParseTime("20261307180000"));
    }

    [Fact]
    public void Finds_what_is_on_now_and_next()
    {
        var g = new Guide(Xmltv.Parse(Sample));
        Assert.Equal("News at Six", g.Now("bbc1", At(18, 30))?.Title);
        Assert.Equal("Football Tonight", g.Next("bbc1", At(18, 30))?.Title);
        Assert.Equal("Football Tonight", g.Now("bbc1", At(19))?.Title);          // a programme starts at its start, ends before its stop
        Assert.Null(g.Now("bbc1", At(20))); Assert.Null(g.Now("nope", At(18))); Assert.Null(g.Now(null, At(18)));
        Assert.Equal("BBC1", "BBC1"); Assert.Equal("News at Six", g.Now("BBC1", At(18, 1))?.Title);   // channel ids are not case sensitive
    }

    [Fact]
    public void Lists_a_window_and_what_catch_up_could_offer()
    {
        var g = new Guide(Xmltv.Parse(Sample));
        Assert.Equal(2, g.Between("bbc1", At(18, 30), At(19, 30)).Count);
        var past = g.Past("bbc1", At(20, 30), 3);
        Assert.Equal(new[] { "Football Tonight", "News at Six" }, past.Select(p => p.Title).ToArray());       // newest first
        Assert.Empty(g.Past("bbc1", At(18, 30), 3).Where(p => p.Title == "Football Tonight"));                 // not finished yet
    }

    [Fact]
    public void Alerts_find_a_word_in_a_title_or_description_from_now_on()
    {
        var g = new Guide(Xmltv.Parse(Sample));
        Assert.Equal(new[] { "Football Tonight" }, g.Alerts(new[] { "football" }, At(18), At(23)).Select(p => p.Title).ToArray());
        Assert.Equal(new[] { "Drama" }, g.Alerts(new[] { "cricket" }, At(18), At(23)).Select(p => p.Title).ToArray());
        Assert.Empty(g.Alerts(new[] { "football" }, At(20), At(23)));            // it has already started
        Assert.Empty(g.Alerts(new[] { " ", "a" }, At(18), At(23)));              // a blank or one-letter word would match everything
    }

    [Fact]
    public void A_guide_that_tries_to_load_an_outside_file_is_refused_not_followed()
    {
        var evil = "<?xml version=\"1.0\"?><!DOCTYPE tv [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><tv><programme start=\"20261107180000\" stop=\"20261107190000\" channel=\"a\"><title>&x;</title></programme></tv>";
        Assert.Throws<InvalidOperationException>(() => Xmltv.Parse(evil));
        var bomb = "<?xml version=\"1.0\"?><!DOCTYPE tv [<!ENTITY a \"aaaaaaaaaa\"><!ENTITY b \"&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;\">]><tv><programme start=\"20261107180000\" stop=\"20261107190000\" channel=\"a\"><title>&b;</title></programme></tv>";
        Assert.Throws<InvalidOperationException>(() => Xmltv.Parse(bomb));
    }

    [Fact]
    public void Broken_XML_is_reported_not_crashed_on_and_the_size_is_capped()
    {
        Assert.Throws<InvalidOperationException>(() => Xmltv.Parse("<tv><programme"));
        Assert.Single(Xmltv.Parse(Sample, maxProgrammes: 1));
    }
}
