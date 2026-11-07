using StreamSetu.Core;
using Xunit;

namespace StreamSetu.Core.Tests;

public class TagsTests
{
    [Theory]
    [InlineData("EN | Heat (1995)", "English")] [InlineData("[FR] Le Film", "French")] [InlineData("|TE| Baahubali", "Telugu")] [InlineData("DE: Tatort", "German")]
    [InlineData("UK - BBC One", "English")] [InlineData("(HI) Sholay", "Hindi")]
    public void Reads_the_language_prefix(string title, string language) => Assert.Equal(language, Tags.Of(title).Language);

    [Theory]
    [InlineData("CNN - News")] [InlineData("Heat (1995)")] [InlineData("AB | Mystery code")] [InlineData("The Matrix")]
    public void A_prefix_that_is_not_a_known_language_is_not_taken_for_one(string title) => Assert.Null(Tags.Of(title).Language);

    [Theory]
    [InlineData("Movie 4K HDR", Quality.Uhd4K)] [InlineData("Movie UHD", Quality.Uhd4K)] [InlineData("Movie 2160p", Quality.Uhd4K)] [InlineData("Movie FHD", Quality.Hd1080)]
    [InlineData("Movie 1080p", Quality.Hd1080)] [InlineData("Movie HD", Quality.Hd720)] [InlineData("Movie 720p", Quality.Hd720)] [InlineData("Movie SD", Quality.Sd)] [InlineData("Movie", Quality.Unknown)]
    public void Reads_the_picture_quality(string title, Quality expected) => Assert.Equal(expected, Tags.Of(title).Quality);

    [Fact]
    public void Reads_the_extras_and_the_cinema_recording_flag()
    {
        var t = Tags.Of("Film 4K HDR Dolby Vision Atmos 5.1");
        Assert.True(t.Hdr); Assert.True(t.DolbyVision); Assert.True(t.Atmos); Assert.True(t.Surround51); Assert.False(t.Cinema);
        Assert.True(Tags.Of("Film HDCAM").Cinema); Assert.True(Tags.Of("Film TS").Cinema); Assert.False(Tags.Of("Constants").Cinema);
    }

    [Fact]
    public void The_same_thing_under_different_decorations_has_the_same_name()
    {
        Assert.Equal("bbc one", Tags.Normalize("EN | BBC One HD")); Assert.Equal("bbc one", Tags.Normalize("UK: BBC One FHD")); Assert.Equal("bbc one", Tags.Normalize("BBC One 4K"));
        Assert.Equal("heat 1995", Tags.Normalize("Heat (1995) 1080p x265")); Assert.NotEqual(Tags.Normalize("BBC One"), Tags.Normalize("BBC Two"));
    }

    private static Item Movie(string id, string title, int? year = 1995) => new() { Id = id, Kind = Kind.Movie, Title = title, Group = "Movies", Year = year, Url = "http://h/" + id };

    [Fact]
    public void The_best_copy_of_a_film_comes_first_and_a_cinema_recording_never_does()
    {
        var all = new[] { Movie("a", "Heat HDCAM"), Movie("b", "Heat 720p"), Movie("c", "Heat 4K"), Movie("d", "Heat 1080p"), Movie("e", "Other 4K"), Movie("f", "Heat 4K", 2001) };
        var copies = Versions.Copies(all[0], all);
        Assert.Equal(new[] { "c", "d", "b", "a" }, copies.Select(m => m.Id).ToArray());          // not the other film, not another year
        Assert.True(Versions.Rank("Heat 4K HDR") > Versions.Rank("Heat 4K"));
    }

    [Fact]
    public void A_channel_that_stops_working_is_looked_up_in_the_other_connections()
    {
        var a = new Playlist("a", "A", PlaylistKind.M3u, "x"); var b = new Playlist("b", "B", PlaylistKind.M3u, "y"); var c = new Playlist("c", "C", PlaylistKind.M3u, "z");
        Item Ch(string id, string t) => new() { Id = id, Kind = Kind.Live, Title = t, Group = "G", Url = "http://h/" + id };
        var alts = Failover.Alternatives(a, Ch("1", "EN | BBC One HD"), new (Playlist, IEnumerable<Item>)[]
        {
            (a, new[] { Ch("9", "BBC One") }),                                                     // the same connection is not an alternative
            (b, new[] { Ch("2", "UK: BBC One"), Ch("3", "UK: BBC One FHD"), Ch("4", "BBC Two") }), // the better copy, only one per connection
            (c, new[] { Ch("5", "Sky News") }),
        });
        var only = Assert.Single(alts);
        Assert.Equal("b", only.Playlist.Id); Assert.Equal("3", only.Channel.Id);
    }
}
