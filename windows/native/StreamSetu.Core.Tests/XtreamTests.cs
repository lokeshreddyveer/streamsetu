using System.Text.Json;
using StreamSetu.Core;
using Xunit;

namespace StreamSetu.Core.Tests;

public class XtreamTests
{
    private const string Address = "http://panel.example:8080/c/";
    private static JsonElement J(string json) => JsonDocument.Parse(json).RootElement.Clone();

    [Fact]
    public void Normalises_what_people_paste_as_the_server_address()
    {
        Assert.Equal("http://panel.example:8080", Xtream.NormalizeHost("panel.example:8080/c/"));
        Assert.Equal("https://panel.example", Xtream.NormalizeHost("https://panel.example/player_api.php"));
    }

    [Fact]
    public void Builds_API_and_stream_addresses_with_the_login_encoded()
    {
        Assert.Equal("http://panel.example:8080/player_api.php?username=us+er&password=p%26w&action=get_live_streams", Xtream.ApiUrl(Address, "us er", "p&w", "get_live_streams"));
        Assert.Equal("http://panel.example:8080/live/u/p%20w/5.m3u8", Xtream.StreamUrl(Address, "u", "p w", Kind.Live, "5"));
        Assert.Equal("http://panel.example:8080/movie/u/p/9.mkv", Xtream.StreamUrl(Address, "u", "p", Kind.Movie, "9", ".mkv"));
    }

    [Fact]
    public void Treats_false_null_and_keyed_objects_as_lists()
    {
        Assert.Empty(Xtream.AsList(J("false"))); Assert.Empty(Xtream.AsList(J("null"))); Assert.Equal(2, Xtream.AsList(J("""{"a":{"x":1},"b":{"x":2}}""")).Count());
    }

    [Fact]
    public void Reads_the_account_end_date_refusal_and_not_active()
    {
        var a = Xtream.ParseAccount(J("""{"user_info":{"auth":1,"status":"Active","exp_date":"1893456000","max_connections":"2"}}"""));
        Assert.True(a.Active); Assert.Equal(2, a.MaxConnections); Assert.Equal(2030, a.Expires?.UtcDateTime.Year);
        Assert.Contains("refused", Assert.Throws<InvalidOperationException>(() => Xtream.ParseAccount(J("""{"user_info":{"auth":0}}"""))).Message);
        Assert.False(Xtream.ParseAccount(J("""{"user_info":{"auth":1,"status":"Expired"}}""")).Active);
        Assert.Throws<InvalidOperationException>(() => Xtream.ParseAccount(J("{}")));
    }

    [Fact]
    public void Lists_channels_with_their_folder_and_skips_divider_rows()
    {
        var live = Xtream.ParseLive(Address, "u", "p", J("""[{"stream_id":1,"name":"BBC One","category_id":"7","epg_channel_id":"bbc1"},{"stream_id":2,"name":"#### SPORT ####","category_id":"7"}]"""), J("""[{"category_id":"7","category_name":"UK"}]"""));
        var one = Assert.Single(live);
        Assert.Equal("UK", one.Group); Assert.Equal("http://panel.example:8080/live/u/p/1.m3u8", one.Url); Assert.Equal("bbc1", one.EpgId);
    }

    [Fact]
    public void Lists_movies_with_their_file_type_and_year()
    {
        var m = Xtream.ParseMovies(Address, "u", "p", J("""{"a":{"stream_id":9,"name":"Heat","container_extension":"mkv","year":"1995","rating_5based":4.5}}"""), J("false"));
        Assert.Equal("mkv", m[0].Ext); Assert.Equal(1995, m[0].Year); Assert.EndsWith("movie/u/p/9.mkv", m[0].Url); Assert.Equal(4.5, m[0].Rating);
    }

    [Fact]
    public void Lists_episodes_season_by_season_in_order()
    {
        var eps = Xtream.ParseEpisodes(Address, "u", "p", J("""{"episodes":{"2":[{"id":"30","episode_num":1,"season":2,"title":"Back"}],"1":[{"id":"21","episode_num":2,"title":"Two"},{"id":"20","episode_num":1,"title":"One"}]}}"""));
        Assert.Equal(new[] { (1, 1), (1, 2), (2, 1) }, eps.Select(e => (e.Season, e.Number)).ToArray());
        Assert.Equal("http://panel.example:8080/series/u/p/20.mp4", eps[0].Url);
    }

    [Fact]
    public void Lists_series_with_plot_and_series_id()
    {
        var s = Xtream.ParseSeriesList(J("""[{"series_id":5,"name":"The Show","category_id":"3","plot":"A story","releaseDate":"2019-04-01"}]"""), J("""[{"category_id":"3","category_name":"Drama"}]"""));
        Assert.Equal("Drama", s[0].Group); Assert.Equal("5", s[0].SeriesId); Assert.Equal(2019, s[0].Year); Assert.Equal("A story", s[0].Plot);
    }
}
