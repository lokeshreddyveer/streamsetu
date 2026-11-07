using StreamSetu.Core;
using Xunit;

namespace StreamSetu.Core.Tests;

public class M3uTests
{
    private const string Sample = """
#EXTM3U
#EXTINF:-1 tvg-id="bbc1.uk" tvg-logo="http://x/bbc.png" group-title="News, UK",BBC One HD
http://host/live/u/p/1.ts
#EXTINF:-1 group-title="Movies",Heat (1995)
http://host/movie/u/p/10.mkv
#EXTINF:-1 group-title="Series",The Show S01E02
http://host/series/u/p/21.mp4
#EXTINF:-1 group-title="Series",The Show S01E01
http://host/series/u/p/20.mp4
#EXTVLCOPT:http-user-agent=x
#EXTINF:-1,Broken entry
not-a-url
#EXTINF:-1 group-title="News, UK",BBC One HD
http://host/live/u/p/1.ts

""";

    [Fact]
    public void Reads_titles_with_commas_in_the_group_logos_and_guide_ids()
    {
        var bbc = M3u.Parse(Sample).Single(i => i.Title == "BBC One HD");
        Assert.Equal(Kind.Live, bbc.Kind); Assert.Equal("News, UK", bbc.Group); Assert.Equal("http://x/bbc.png", bbc.Logo); Assert.Equal("bbc1.uk", bbc.EpgId);
    }

    [Fact]
    public void Drops_entries_with_no_address_and_repeated_addresses()
    {
        var items = M3u.Parse(Sample);
        Assert.DoesNotContain(items, i => i.Title == "Broken entry");
        Assert.Single(items, i => i.Title == "BBC One HD");
    }

    [Fact]
    public void Sorts_entries_into_live_movies_and_series_and_groups_episodes_under_one_show_in_order()
    {
        var lib = M3u.ToLibrary(M3u.Parse(Sample));
        Assert.Single(lib.Live); Assert.Single(lib.Movies); Assert.Single(lib.Series);
        var eps = lib.Episodes["the show"];
        Assert.Equal(new int?[] { 1, 2 }, eps.Select(e => e.Episode).ToArray()); Assert.Equal(1, eps[0].Season);
    }

    [Fact]
    public void Classifies_by_path_first_then_by_group_and_file_name()
    {
        Assert.Equal(Kind.Movie, M3u.Classify("http://h/movie/u/p/1.mp4", "", "x"));
        Assert.Equal(Kind.Movie, M3u.Classify("http://h/a.mp4", "", "x"));
        Assert.Equal(Kind.Live, M3u.Classify("http://h/a.ts", "Sports", "Match"));
        Assert.Equal(Kind.Series, M3u.Classify("http://h/a.ts", "TV Shows", "x"));
    }

    [Fact]
    public void Handles_Windows_line_endings_and_an_empty_file()
    {
        Assert.Equal(M3u.Parse(Sample).Count, M3u.Parse(Sample.Replace("\n", "\r\n")).Count);
        Assert.Empty(M3u.Parse(""));
    }

    [Fact]
    public void Reads_the_season_and_episode_out_of_the_title_and_the_file_type_out_of_the_address()
    {
        var ep = M3u.Parse(Sample).First(i => i.Kind == Kind.Series);
        Assert.Equal("The Show", ep.Title); Assert.Equal("mp4", ep.Ext);
    }
}
