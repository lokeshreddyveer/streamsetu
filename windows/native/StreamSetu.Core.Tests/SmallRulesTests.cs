using System.Text.Json;
using StreamSetu.Core;
using Xunit;

namespace StreamSetu.Core.Tests;

public sealed class SmallRulesTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "streamsetu-test-" + Guid.NewGuid().ToString("N"));
    public void Dispose() { try { Directory.Delete(_dir, true); } catch (IOException) { } }
    private static readonly DateTimeOffset Now = new(2026, 11, 7, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void A_subscription_warns_from_a_week_before_it_ends()
    {
        string? W(double days) => new Account(true, "Active", Now.AddDays(days).AddHours(1), 1).Warning(Now);
        Assert.Null(W(30)); Assert.Null(W(8)); Assert.Equal("This subscription ends in 7 days.", W(7)); Assert.Equal("This subscription ends in 3 days.", W(3));
        Assert.Equal("This subscription ends tomorrow.", W(1)); Assert.Equal("This subscription ends today.", W(0)); Assert.Equal("This subscription has ended.", W(-2));
        Assert.Null(new Account(true, "Active", null, 1).Warning(Now));                       // a panel that gives no end date says nothing
    }

    [Fact]
    public void Catch_up_addresses_use_the_providers_archive_form_in_UTC()
    {
        var start = new DateTimeOffset(2026, 11, 7, 20, 30, 0, TimeSpan.FromHours(2));
        Assert.Equal("http://panel.example:8080/timeshift/u/p%20w/60/2026-11-07:18-30/55.ts", Xtream.CatchupUrl("panel.example:8080/c/", "u", "p w", "55", start, 60));
    }

    [Fact]
    public void Titles_and_series_carry_the_date_the_provider_added_them()
    {
        var movies = Xtream.ParseMovies("h", "u", "p", JsonDocument.Parse("""[{"stream_id":1,"name":"A","added":"1793000000"},{"stream_id":2,"name":"B","added":"1793000000000"},{"stream_id":3,"name":"C","added":"zero"}]""").RootElement, JsonDocument.Parse("[]").RootElement);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1793000000), movies[0].Added); Assert.Equal(movies[0].Added, movies[1].Added); Assert.Null(movies[2].Added);
        var series = Xtream.ParseSeriesList(JsonDocument.Parse("""[{"series_id":1,"name":"S","last_modified":"1793000000"}]""").RootElement, JsonDocument.Parse("[]").RootElement);
        Assert.Equal(DateTimeOffset.FromUnixTimeSeconds(1793000000), series[0].Added);
    }

    [Fact]
    public void The_sleep_timer_fires_once_and_can_be_cancelled()
    {
        var clock = Now; var t = new SleepTimer(() => clock);
        Assert.False(t.Running); Assert.False(t.Due());
        t.Start(TimeSpan.FromMinutes(30)); Assert.True(t.Running); Assert.Equal(TimeSpan.FromMinutes(30), t.Remaining);
        clock = Now.AddMinutes(29); Assert.False(t.Due()); Assert.Equal(TimeSpan.FromMinutes(1), t.Remaining);
        clock = Now.AddMinutes(31); Assert.True(t.Due()); Assert.False(t.Due()); Assert.False(t.Running); Assert.Null(t.Remaining);
        t.Start(TimeSpan.FromMinutes(5)); t.Cancel(); clock = Now.AddHours(5); Assert.False(t.Due());
        t.Start(TimeSpan.Zero); Assert.False(t.Running);
    }

    [Fact]
    public void A_finished_title_is_remembered_as_watched_and_can_be_unmarked()
    {
        var s = new LocalStore(_dir);
        s.SaveProgress("m", 600, 7200); Assert.DoesNotContain("m", s.Watched());
        s.SaveProgress("m", 7190, 7200); Assert.Contains("m", s.Watched()); Assert.Null(s.ProgressOf("m"));
        s.MarkWatched("n"); s.MarkWatched("n"); Assert.Equal(2, new LocalStore(_dir).Watched().Count);
        s.MarkUnwatched("m"); Assert.DoesNotContain("m", s.Watched());
    }
}
