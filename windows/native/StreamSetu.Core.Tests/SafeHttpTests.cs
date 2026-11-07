using System.Net;
using System.Net.Sockets;
using StreamSetu.Core;
using Xunit;

namespace StreamSetu.Core.Tests;

public sealed class SafeHttpTests : IDisposable
{
    private readonly HttpListener _listener = new();
    private readonly int _port;
    private readonly CancellationTokenSource _stop = new();

    public SafeHttpTests()
    {
        var probe = new TcpListener(IPAddress.Loopback, 0); probe.Start(); _port = ((IPEndPoint)probe.LocalEndpoint).Port; probe.Stop();
        _listener.Prefixes.Add($"http://127.0.0.1:{_port}/"); _listener.Prefixes.Add($"http://localhost:{_port}/");
        _listener.Start();
        _ = Task.Run(async () =>
        {
            while (!_stop.IsCancellationRequested)
            {
                HttpListenerContext c;
                try { c = await _listener.GetContextAsync(); } catch { return; }
                var path = c.Request.Url!.AbsolutePath;
                if (path == "/redir-local") { c.Response.StatusCode = 302; c.Response.RedirectLocation = $"http://localhost:{_port}/text"; }
                else if (path == "/redir-ok") { c.Response.StatusCode = 302; c.Response.RedirectLocation = "/text"; }
                else if (path == "/loop") { c.Response.StatusCode = 302; c.Response.RedirectLocation = "/loop"; }
                else { var body = "hello playlist"u8.ToArray(); c.Response.OutputStream.Write(body); }
                c.Response.Close();
            }
        });
    }

    public void Dispose() { _stop.Cancel(); _listener.Close(); }

    private string Url(string path, string host = "127.0.0.1") => $"http://{host}:{_port}{path}";
    private static SafeHttp Client(params string[] listed) { var allow = new HostAllowList(); foreach (var h in listed) allow.Add(h); return new SafeHttp(allow, "StreamSetu-test"); }
    private static async Task<Refusal> RefusalOf(Func<Task> action) => (await Assert.ThrowsAsync<FetchRefusedException>(action)).Reason;

    [Theory]
    [InlineData("127.0.0.1")] [InlineData("127.8.8.8")] [InlineData("0.0.0.0")] [InlineData("10.1.2.3")] [InlineData("172.16.0.1")] [InlineData("172.31.255.255")]
    [InlineData("192.168.1.1")] [InlineData("169.254.169.254")] [InlineData("100.64.0.1")] [InlineData("224.0.0.1")] [InlineData("255.255.255.255")]
    [InlineData("::1")] [InlineData("::")] [InlineData("fe80::1")] [InlineData("fd00::1")] [InlineData("fc12::1")] [InlineData("ff02::1")] [InlineData("::ffff:127.0.0.1")] [InlineData("::ffff:192.168.1.1")]
    public void This_computer_and_the_local_network_are_blocked(string ip) => Assert.True(AddressPolicy.IsBlocked(IPAddress.Parse(ip)), ip);

    [Theory]
    [InlineData("8.8.8.8")] [InlineData("1.1.1.1")] [InlineData("93.184.216.34")] [InlineData("172.32.0.1")] [InlineData("100.128.0.1")] [InlineData("2606:4700:4700::1111")] [InlineData("::ffff:8.8.8.8")]
    public void Public_addresses_are_not_blocked(string ip) => Assert.False(AddressPolicy.IsBlocked(IPAddress.Parse(ip)), ip);

    [Fact]
    public void Only_web_addresses_without_a_login_pass_the_first_check()
    {
        Assert.Null(AddressPolicy.Check(new Uri("http://a.example/x"))); Assert.Null(AddressPolicy.Check(new Uri("https://a.example/x")));
        Assert.Equal(Refusal.NotWeb, AddressPolicy.Check(new Uri("file:///etc/passwd"))); Assert.Equal(Refusal.NotWeb, AddressPolicy.Check(new Uri("ftp://a.example/x")));
        Assert.Equal(Refusal.HasLogin, AddressPolicy.Check(new Uri("http://user:pw@a.example/x"))); Assert.Equal(Refusal.HasLogin, AddressPolicy.Check(new Uri("http://user@a.example/x")));
    }

    [Fact]
    public async Task This_computer_is_not_reachable_unless_the_host_is_in_a_connection()
    {
        using (var closed = Client()) Assert.Equal(Refusal.Blocked, await RefusalOf(() => closed.FetchTextAsync(Url("/text"))));
        using var open = Client("127.0.0.1");
        Assert.Equal("hello playlist", await open.FetchTextAsync(Url("/text")));
    }

    [Fact]
    public async Task The_local_network_and_cloud_metadata_are_refused_without_connecting()
    {
        using var c = Client();
        foreach (var target in new[] { "http://192.168.1.1/admin", "http://10.0.0.1/", "http://169.254.169.254/latest/meta-data/", "http://[::1]/", "http://[fd00::1]/", "http://0.0.0.0:1/" })
            Assert.True(Refusal.Blocked == await RefusalOf(() => c.FetchTextAsync(target)), target);
    }

    [Fact]
    public async Task A_redirect_to_a_place_that_is_not_allowed_is_refused_at_that_step()
    {
        using var c = Client("127.0.0.1");
        Assert.Equal("hello playlist", await c.FetchTextAsync(Url("/redir-ok")));                                  // inside the allowed host: followed
        Assert.Equal(Refusal.Blocked, await RefusalOf(() => c.FetchTextAsync(Url("/redir-local"))));              // to another name for this computer: refused
        Assert.Equal(Refusal.TooManyRedirects, await RefusalOf(() => c.FetchTextAsync(Url("/loop"))));            // never ends: stops after a few steps
    }

    [Fact]
    public async Task Addresses_that_are_not_web_pages_or_carry_a_login_are_refused()
    {
        using var c = Client("127.0.0.1");
        Assert.Equal(Refusal.NotWeb, await RefusalOf(() => c.FetchTextAsync("file:///etc/passwd")));
        Assert.Equal(Refusal.NotWeb, await RefusalOf(() => c.FetchTextAsync("not an address")));
        Assert.Equal(Refusal.HasLogin, await RefusalOf(() => c.FetchTextAsync($"http://user:pw@127.0.0.1:{_port}/text")));
    }

    [Fact]
    public async Task A_name_that_does_not_exist_is_unreachable_not_blocked()
    {
        using var c = Client();
        Assert.Equal(Refusal.Unreachable, await RefusalOf(() => c.FetchTextAsync("http://no-such-host.invalid/")));
    }

    [Fact]
    public async Task A_download_stops_at_its_size_limit()
    {
        using var c = Client("127.0.0.1");
        Assert.Equal("hello", await c.FetchTextAsync(Url("/text"), limit: 5));
    }
}
