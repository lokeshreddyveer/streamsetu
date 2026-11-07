using System.Net;
using StreamSetu.Core;
using Xunit;

namespace StreamSetu.Core.Tests;

public class DnsAndSubtitleTests
{
    // A real-shaped answer for example.com: one question, one A record using a name pointer (0xC00C) back to the question.
    private static byte[] Answer(params byte[][] records)
    {
        var q = DnsWire.BuildQuery("example.com", DnsWire.TypeA).Skip(12).ToArray();                    // the question section
        var header = new byte[] { 0, 0, 0x81, 0x80, 0, 1, 0, (byte)records.Length, 0, 0, 0, 0 };
        return header.Concat(q).Concat(records.SelectMany(r => r)).ToArray();
    }
    private static byte[] A(params byte[] ip) => new byte[] { 0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 1, 0x2C, 0, (byte)ip.Length }.Concat(ip).ToArray();
    private static byte[] Aaaa(IPAddress ip) => new byte[] { 0xC0, 0x0C, 0, 28, 0, 1, 0, 0, 1, 0x2C, 0, 16 }.Concat(ip.GetAddressBytes()).ToArray();

    [Fact]
    public void A_query_is_a_valid_DNS_question()
    {
        var q = DnsWire.BuildQuery("www.example.com", DnsWire.TypeAaaa, 0x1234);
        Assert.Equal(new byte[] { 0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0 }, q.Take(12).ToArray());
        Assert.Equal(new byte[] { 3, (byte)'w', (byte)'w', (byte)'w', 7 }, q.Skip(12).Take(5).ToArray());
        Assert.Equal(new byte[] { 0, 0, 28, 0, 1 }, q.Skip(q.Length - 5).ToArray());
        Assert.Throws<ArgumentException>(() => DnsWire.BuildQuery(new string('a', 64) + ".com", 1));
    }

    [Fact]
    public void Reads_A_and_AAAA_answers_including_name_pointers()
    {
        var v6 = IPAddress.Parse("2606:2800:220:1:248:1893:25c8:1946");
        var got = DnsWire.ParseAnswer(Answer(A(93, 184, 216, 34), Aaaa(v6), A(1, 2, 3, 4)));
        Assert.Equal(new[] { IPAddress.Parse("93.184.216.34"), v6, IPAddress.Parse("1.2.3.4") }, got.ToArray());
    }

    [Fact]
    public void An_error_code_gives_nothing()
    {
        var m = Answer(A(1, 2, 3, 4)); m[3] = 0x83;            // NXDOMAIN
        Assert.Empty(DnsWire.ParseAnswer(m));
    }

    [Fact]
    public void Cut_off_or_hostile_answers_never_throw_and_never_give_wrong_addresses()
    {
        var good = Answer(A(93, 184, 216, 34));
        for (int cut = 0; cut < good.Length; cut++) { var parsed = DnsWire.ParseAnswer(good.Take(cut).ToArray()); Assert.True(parsed.Count <= 1); }           // every truncation
        Assert.Empty(DnsWire.ParseAnswer(Array.Empty<byte>()));
        var wrongLength = Answer(new byte[] { 0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 1, 0, 5, 1, 2, 3, 4, 5 });                  // an A record claiming 5 bytes
        Assert.Empty(DnsWire.ParseAnswer(wrongLength));
        var overrun = Answer(new byte[] { 0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 1, 0xFF, 0xFF, 1, 2 });                         // a length far past the end
        Assert.Empty(DnsWire.ParseAnswer(overrun));
        var loop = new byte[] { 0, 0, 0x81, 0x80, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 12, 0, 1, 0, 1 };                           // a name that points at itself
        Assert.Empty(DnsWire.ParseAnswer(loop));
        var random = new Random(7); var junk = new byte[512];
        for (int i = 0; i < 2000; i++) { random.NextBytes(junk); junk[2] = 0x81; junk[3] = 0x80; _ = DnsWire.ParseAnswer(junk); }
    }

    private sealed class FakeDoh(Func<byte[], byte[]?> answer) : HttpMessageHandler
    {
        public int Calls;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Interlocked.Increment(ref Calls);
            Assert.Equal("application/dns-message", request.Content!.Headers.ContentType!.MediaType);
            var reply = answer(await request.Content.ReadAsByteArrayAsync(ct));
            return reply is null ? new HttpResponseMessage(HttpStatusCode.ServiceUnavailable) : new HttpResponseMessage { Content = new ByteArrayContent(reply) };
        }
    }

    private sealed class FixedResolver(params string[] ips) : IHostResolver
    {
        public int Calls;
        public Task<IPAddress[]> ResolveAsync(string host, CancellationToken ct) { Calls++; return Task.FromResult(ips.Select(IPAddress.Parse).ToArray()); }
    }

    [Fact]
    public async Task The_encrypted_resolver_asks_the_provider_caches_and_does_not_use_the_system()
    {
        var handler = new FakeDoh(q => q[^4] == 0 && q[^3] == DnsWire.TypeA ? Answer(A(9, 9, 9, 9)) : Answer());          // the query type is in its last four bytes; answered for A only
        var system = new FixedResolver("6.6.6.6"); var clock = DateTimeOffset.UtcNow;
        var doh = new DohResolver(DnsProvider.Cloudflare, new HttpClient(handler), system, () => clock);
        Assert.Equal(new[] { IPAddress.Parse("9.9.9.9") }, await doh.ResolveAsync("example.com", default));
        var calls = handler.Calls; Assert.Equal(2, calls);                                                  // one for A, one for AAAA
        await doh.ResolveAsync("example.com", default); Assert.Equal(calls, handler.Calls);                 // cached
        clock = clock.AddMinutes(6); await doh.ResolveAsync("example.com", default); Assert.Equal(calls * 2, handler.Calls);
        Assert.Equal(0, system.Calls);
        Assert.Equal(new[] { IPAddress.Parse("10.0.0.5") }, await doh.ResolveAsync("10.0.0.5", default));    // a number is not looked up
    }

    [Fact]
    public async Task When_the_provider_fails_the_system_is_used_so_the_app_keeps_working()
    {
        var system = new FixedResolver("6.6.6.6");
        var doh = new DohResolver(DnsProvider.Google, new HttpClient(new FakeDoh(_ => null)), system);
        Assert.Equal(new[] { IPAddress.Parse("6.6.6.6") }, await doh.ResolveAsync("example.com", default)); Assert.Equal(1, system.Calls);
    }

    [Fact]
    public async Task An_encrypted_resolver_cannot_be_used_to_reach_the_local_network()
    {
        var doh = new DohResolver(DnsProvider.Quad9, new HttpClient(new FakeDoh(_ => Answer(A(192, 168, 1, 1)))));        // a hostile or hijacked answer
        using var http = new SafeHttp(new HostAllowList(), "test", resolver: doh);
        var e = await Assert.ThrowsAsync<FetchRefusedException>(() => http.FetchTextAsync("http://rebind.example/"));
        Assert.Equal(Refusal.Blocked, e.Reason);
    }

    [Fact]
    public void Only_https_custom_servers_are_accepted()
    {
        Assert.NotNull(DnsProvider.Custom("https://dns.example/dns-query")); Assert.Null(DnsProvider.Custom("http://dns.example/dns-query")); Assert.Null(DnsProvider.Custom("nonsense"));
        Assert.All(DnsProvider.Presets, p => Assert.StartsWith("https://", p.Url));
    }

    // ----- Subtitles -----

    private const string Search = """
{"data":[
 {"attributes":{"language":"en","release":"Heat.1995.1080p","download_count":50000,"moviehash_match":false,"files":[{"file_id":111}],"feature_details":{"title":"Heat","year":1995}}},
 {"attributes":{"language":"en","release":"Heat.1995.EXACT","download_count":10,"moviehash_match":true,"files":[{"file_id":222}],"feature_details":{"title":"Heat","year":1995}}},
 {"attributes":{"language":"fr","release":"Heat.fr","download_count":99999,"files":[{"file_id":333}],"feature_details":{"title":"Heat","year":1995}}},
 {"attributes":{"language":"en","release":"Heat.2","download_count":5000,"files":[{"file_id":444}],"feature_details":{"title":"Heat Wave","year":2001}}},
 {"attributes":{"language":"en","files":[]}},
 {"nothing":true}
]}
""";

    [Fact]
    public void Ranks_an_exact_file_match_first_and_explains_each_result()
    {
        var ranked = Subtitles.Rank(Subtitles.ParseSearch(Search), "EN | Heat (1995) 1080p", 1995, "en");
        Assert.Equal(new[] { "222", "111", "444", "333" }, ranked.Select(r => r.Candidate.FileId).ToArray());
        Assert.Contains("exact file", ranked[0].Reason); Assert.Contains("another language", ranked[3].Reason); Assert.Contains("different title", ranked[2].Reason);
    }

    [Fact]
    public void Automatic_loading_takes_only_a_confident_match()
    {
        var ranked = Subtitles.Rank(Subtitles.ParseSearch(Search), "Heat", 1995, "en");
        Assert.Equal("222", Subtitles.Confident(ranked)?.Candidate.FileId);
        Assert.Equal("111", Subtitles.Confident(ranked.Where(r => !r.Candidate.HashMatch))?.Candidate.FileId);     // same title, year and language is enough
        Assert.Null(Subtitles.Confident(Subtitles.Rank(Subtitles.ParseSearch(Search), "Something Else", 2020, "en")));
        Assert.Null(Subtitles.Confident(Subtitles.Rank(Subtitles.ParseSearch(Search), "Heat", 1995, "de")));            // nothing in German
    }

    [Fact]
    public void Requests_and_answers_are_built_and_read_safely()
    {
        Assert.Equal("https://api.opensubtitles.com/api/v1/subtitles?query=heat&year=1995&languages=en&order_by=download_count", Subtitles.SearchUrl("EN | Heat HD", 1995, "EN"));
        Assert.Equal("""{"file_id":123}""", Subtitles.DownloadBody("123")); Assert.Equal("""{"file_id":0}""", Subtitles.DownloadBody("12\"}"));
        Assert.Equal("""{"username":"a\"b","password":"p"}""", Subtitles.LoginBody("a\"b", "p").Replace("\\u0022", "\\\""));
        Assert.Equal("T", Subtitles.ParseToken("""{"token":"T"}""")); Assert.Null(Subtitles.ParseToken("not json"));
        Assert.Equal("https://dl.example/x.srt", Subtitles.ParseLink("""{"link":"https://dl.example/x.srt"}""")); Assert.Null(Subtitles.ParseLink("""{"link":"file:///etc/passwd"}""")); Assert.Null(Subtitles.ParseLink("""{"link":"http://x/y"}"""));
        Assert.Throws<InvalidOperationException>(() => Subtitles.ParseSearch("<html>"));
        Assert.Empty(Subtitles.ParseSearch("""{"data":"nope"}"""));
        Assert.Equal("k", Subtitles.Headers("k", null)["Api-Key"]); Assert.Equal("Bearer t", Subtitles.Headers("k", "t")["Authorization"]);
    }
}
