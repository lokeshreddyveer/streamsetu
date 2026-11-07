using System.IO.Compression;
using System.Text;
using StreamSetu.Core;
using Xunit;

namespace StreamSetu.Core.Tests;

public sealed class SettingsAndFilesTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "streamsetu-test-" + Guid.NewGuid().ToString("N"));
    public void Dispose() { try { Directory.Delete(_dir, true); } catch (IOException) { } }

    [Fact]
    public void Settings_are_remembered_and_the_DNS_choice_is_read_safely()
    {
        var store = new LocalStore(_dir);
        Assert.Equal("en", AppSettings.Load(store).SubtitleLanguage); Assert.Null(AppSettings.Load(store).Resolver);
        (AppSettings.Load(store) with { Dns = "quad9", AlertWords = new() { "cricket" }, GuideUrls = new() { ["p"] = "http://g/guide.xml" } }).Save(store);
        var back = AppSettings.Load(new LocalStore(_dir));
        Assert.Equal("Quad9", back.Resolver?.Name); Assert.Equal(new[] { "cricket" }, back.AlertWords); Assert.Equal("http://g/guide.xml", back.GuideUrls["p"]);
        Assert.Equal("Custom", (back with { Dns = "https://dns.example/q" }).Resolver?.Name);
        Assert.Null((back with { Dns = "http://dns.example/q" }).Resolver);          // not encrypted: refused rather than used
    }

    [Fact]
    public void An_Xtream_guide_is_at_xmltv_php_and_other_guides_come_from_Settings_when_they_are_web_addresses()
    {
        var x = new Playlist("x", "X", PlaylistKind.Xtream, "panel.example:8080/c/", "us er", "playlist:x"); var m = new Playlist("m", "M", PlaylistKind.M3u, "http://h/a.m3u");
        Assert.Equal("http://panel.example:8080/xmltv.php?username=us%20er&password=p%26w", GuideLoader.AddressFor(x, "p&w", new AppSettings()));
        Assert.Null(GuideLoader.AddressFor(m, null, new AppSettings()));
        Assert.Equal("https://g/guide.xml.gz", GuideLoader.AddressFor(m, null, new AppSettings { GuideUrls = new() { ["m"] = "https://g/guide.xml.gz" } }));
        Assert.Null(GuideLoader.AddressFor(m, null, new AppSettings { GuideUrls = new() { ["m"] = "file:///etc/passwd" } }));
    }

    private static byte[] Gzip(string text) { var ms = new MemoryStream(); using (var z = new GZipStream(ms, CompressionLevel.SmallestSize, true)) z.Write(Encoding.UTF8.GetBytes(text)); return ms.ToArray(); }

    [Fact]
    public void A_gzipped_guide_is_unpacked_and_plain_text_is_left_alone()
    {
        Assert.Equal("<tv/>", SafeHttp.DecodeBody(Gzip("<tv/>"), 1000)); Assert.Equal("<tv/>", SafeHttp.DecodeBody("<tv/>"u8, 1000)); Assert.Equal("", SafeHttp.DecodeBody(ReadOnlySpan<byte>.Empty, 10));
    }

    [Fact]
    public void A_small_file_that_expands_without_end_is_cut_off_at_the_limit()
    {
        var bomb = Gzip(new string('a', 5_000_000));
        Assert.True(bomb.Length < 20_000);
        Assert.Equal(1000, SafeHttp.DecodeBody(bomb, 1000).Length);
        Assert.Throws<InvalidOperationException>(() => SafeHttp.DecodeBody(new byte[] { 0x1f, 0x8b, 1, 2, 3, 4 }, 1000));
    }

    [Fact]
    public async Task An_M3U_file_on_this_computer_can_be_a_connection()
    {
        Directory.CreateDirectory(_dir); var path = Path.Combine(_dir, "list.m3u");
        File.WriteAllText(path, "#EXTM3U\n#EXTINF:-1 group-title=\"News\",One\nhttp://h/live/a/b/1.ts\n");
        var loader = new LibraryLoader(new LibraryLoaderTests.FakeFetcher(new()), new MemorySecretStore());
        Assert.Equal("One", (await loader.LoadAsync(new Playlist("f", "File", PlaylistKind.M3u, path))).Library.Live.Single().Title);
        var e = await Assert.ThrowsAsync<InvalidOperationException>(() => loader.LoadAsync(new Playlist("f", "File", PlaylistKind.M3u, Path.Combine(_dir, "missing.m3u"))));
        Assert.Contains("could not be found", e.Message);
    }
}
