using System.Net;
using System.Net.Sockets;
using System.Text;

namespace StreamSetu.Core;

/// <summary>Hosts the person has put in a connection. Only the app's own screens add to it.</summary>
public sealed class HostAllowList
{
    private readonly HashSet<string> _hosts = new(StringComparer.OrdinalIgnoreCase);
    public void Add(string host) { lock (_hosts) _hosts.Add(Clean(host)); }
    public bool Contains(string host) { lock (_hosts) return _hosts.Contains(Clean(host)); }
    private static string Clean(string host) => host.Trim().Trim('[', ']');
}

public enum Refusal { NotWeb, HasLogin, Blocked, Unreachable, TooManyRedirects }

public sealed class FetchRefusedException(Refusal reason, string message) : Exception(message)
{
    public Refusal Reason { get; } = reason;
}

/// <summary>Where the app may fetch from: web addresses without a login in them, never this computer or the home network, unless the person has put that host in a connection
/// (a provider on the home network is legitimate). The check is made on the address the connection is actually made to, and again at every redirect.</summary>
public static class AddressPolicy
{
    /// <summary>An address that is this computer, this network, or otherwise not the public internet.</summary>
    public static bool IsBlocked(IPAddress ip)
    {
        if (ip.IsIPv4MappedToIPv6) ip = ip.MapToIPv4();
        var b = ip.GetAddressBytes();
        if (ip.AddressFamily == AddressFamily.InterNetwork)
            return b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224
                || (b[0] == 100 && b[1] >= 64 && b[1] < 128)            // carrier-grade NAT, 100.64.0.0/10
                || (b[0] == 169 && b[1] == 254)                          // link-local, including cloud metadata
                || (b[0] == 172 && b[1] >= 16 && b[1] < 32)
                || (b[0] == 192 && b[1] == 168)
                || (b[0] == 192 && b[1] == 0 && b[2] == 2) || (b[0] == 198 && b[1] == 51 && b[2] == 100) || (b[0] == 203 && b[1] == 0 && b[2] == 113);   // documentation
        if (ip.AddressFamily == AddressFamily.InterNetworkV6)
            return IPAddress.IsLoopback(ip) || ip.Equals(IPAddress.IPv6Any) || b[0] == 0xff || (b[0] & 0xfe) == 0xfc || (b[0] == 0xfe && (b[1] & 0xc0) == 0x80);
        return true;
    }

    /// <summary>An address on this network (private, link-local, unique-local): where other devices running StreamSetu are. Loopback is not, and neither is the public internet; sync never connects to those.</summary>
    public static bool IsLocalNetwork(IPAddress ip)
    {
        if (ip.IsIPv4MappedToIPv6) ip = ip.MapToIPv4();
        if (IPAddress.IsLoopback(ip)) return false;
        var b = ip.GetAddressBytes();
        return ip.AddressFamily == AddressFamily.InterNetwork
            ? b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] < 32) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
            : ip.AddressFamily == AddressFamily.InterNetworkV6 && ((b[0] & 0xfe) == 0xfc || (b[0] == 0xfe && (b[1] & 0xc0) == 0x80));
    }

    /// <summary>The part of the rule that needs no lookup: web addresses only, no login in the address.</summary>
    public static Refusal? Check(Uri url)
    {
        if (url.Scheme != Uri.UriSchemeHttp && url.Scheme != Uri.UriSchemeHttps) return Refusal.NotWeb;
        if (url.UserInfo.Length > 0) return Refusal.HasLogin;
        return null;
    }

    public static string Message(Refusal r) => r switch
    {
        Refusal.NotWeb => "Only web addresses can be opened.",
        Refusal.HasLogin => "Put the username and password in the connection, not in the address.",
        Refusal.Blocked => "That address is on this computer or network. Add it as a connection first.",
        Refusal.TooManyRedirects => "That address sent the app around in circles.",
        _ => "That address could not be reached.",
    };
}

/// <summary>Downloads for the app (playlists, provider answers, artwork, subtitles). Every address goes through <see cref="AddressPolicy"/>, redirects are followed here so each step is checked,
/// and a host name is looked up once, with the connection made to exactly the addresses that passed.</summary>
public sealed class SafeHttp : IDisposable
{
    public const int MaxRedirects = 5;
    private readonly HttpClient _client;

    private sealed class BlockedAddressException() : IOException("blocked");

    public SafeHttp(HostAllowList allow, string userAgent, TimeSpan? connectTimeout = null, TimeSpan? timeout = null, IHostResolver? resolver = null)
    {
        resolver ??= new SystemResolver();
        var handler = new SocketsHttpHandler
        {
            AllowAutoRedirect = false,
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate | DecompressionMethods.Brotli,
            ConnectTimeout = connectTimeout ?? TimeSpan.FromSeconds(15),
            UseCookies = false,
            ConnectCallback = async (context, token) =>
            {
                var host = context.DnsEndPoint.Host;
                // An address written as numbers is used as it is (the lookup refuses 0.0.0.0 and :: outright, which would be reported as "unreachable" instead of "blocked").
                var all = IPAddress.TryParse(host.Trim('[', ']'), out var literal) ? new[] { literal } : await resolver.ResolveAsync(host, token).ConfigureAwait(false);
                var usable = allow.Contains(host) ? all : all.Where(a => !AddressPolicy.IsBlocked(a)).ToArray();
                if (usable.Length == 0) throw new BlockedAddressException();
                var socket = new Socket(SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
                try { await socket.ConnectAsync(usable, context.DnsEndPoint.Port, token).ConfigureAwait(false); return new NetworkStream(socket, ownsSocket: true); }
                catch { socket.Dispose(); throw; }
            },
        };
        _client = new HttpClient(handler, disposeHandler: true) { Timeout = timeout ?? TimeSpan.FromMinutes(2) };
        _client.DefaultRequestHeaders.UserAgent.ParseAdd(userAgent);
    }

    /// <summary>A GET that follows redirects itself. The caller disposes the response.</summary>
    public Task<HttpResponseMessage> GetAsync(string url, string? range = null, CancellationToken ct = default, IReadOnlyDictionary<string, string>? headers = null)
        => SendAsync(HttpMethod.Get, url, headers, null, range, ct);

    /// <summary>Any method (WebDAV's PROPFIND, for one). Only GET and HEAD follow redirects; for the others a redirect is handed back as the answer, so a request body is never sent on to a place the person did not choose.</summary>
    public async Task<HttpResponseMessage> SendAsync(HttpMethod method, string url, IReadOnlyDictionary<string, string>? headers, string? body, string? range, CancellationToken ct = default)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var current)) throw new FetchRefusedException(Refusal.NotWeb, AddressPolicy.Message(Refusal.NotWeb));
        for (int hop = 0; hop <= MaxRedirects; hop++)
        {
            if (AddressPolicy.Check(current) is { } refusal) throw new FetchRefusedException(refusal, AddressPolicy.Message(refusal));
            using var request = new HttpRequestMessage(method, current);
            if (range is not null) request.Headers.TryAddWithoutValidation("Range", range);
            if (headers is not null) foreach (var (name, value) in headers) request.Headers.TryAddWithoutValidation(name, value);
            if (body is not null) request.Content = new StringContent(body, Encoding.UTF8, body.TrimStart().StartsWith('{') ? "application/json" : "application/xml");
            HttpResponseMessage response;
            try { response = await _client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false); }
            catch (HttpRequestException e) when (HasBlocked(e)) { throw new FetchRefusedException(Refusal.Blocked, AddressPolicy.Message(Refusal.Blocked)); }
            catch (HttpRequestException) { throw new FetchRefusedException(Refusal.Unreachable, AddressPolicy.Message(Refusal.Unreachable)); }
            if ((method == HttpMethod.Get || method == HttpMethod.Head) && (int)response.StatusCode is >= 300 and < 400 and not 304 && response.Headers.Location is { } location)
            {
                response.Dispose();
                current = new Uri(current, location);
                continue;
            }
            return response;
        }
        throw new FetchRefusedException(Refusal.TooManyRedirects, AddressPolicy.Message(Refusal.TooManyRedirects));
    }

    private static bool HasBlocked(Exception? e) { for (; e is not null; e = e.InnerException) if (e is BlockedAddressException) return true; return false; }

    /// <summary>The text of a web address, read up to <paramref name="limit"/> bytes.</summary>
    public async Task<string> FetchTextAsync(string url, long limit = 50L * 1024 * 1024, CancellationToken ct = default, IReadOnlyDictionary<string, string>? headers = null, HttpMethod? method = null, string? body = null)
    {
        using var response = await SendAsync(method ?? HttpMethod.Get, url, headers, body, null, ct).ConfigureAwait(false);
        if ((int)response.StatusCode >= 400) throw new InvalidOperationException($"The server answered {(int)response.StatusCode}.");
        await using var stream = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
        using var buffer = new MemoryStream();
        var chunk = new byte[81920]; int n;
        while (buffer.Length < limit && (n = await stream.ReadAsync(chunk, ct).ConfigureAwait(false)) > 0) buffer.Write(chunk, 0, (int)Math.Min(n, limit - buffer.Length));
        return DecodeBody(buffer.GetBuffer().AsSpan(0, (int)buffer.Length), limit);
    }

    /// <summary>The bytes of a web address (an image, an installer), read up to <paramref name="limit"/>. Too large is an error, not a silent cut: half a picture or half an installer is worse than none.</summary>
    public async Task<byte[]> FetchBytesAsync(string url, long limit, CancellationToken ct = default, IReadOnlyDictionary<string, string>? headers = null)
    {
        using var response = await SendAsync(HttpMethod.Get, url, headers, null, null, ct).ConfigureAwait(false);
        if ((int)response.StatusCode >= 400) throw new InvalidOperationException($"The server answered {(int)response.StatusCode}.");
        if (response.Content.Headers.ContentLength is { } declared && declared > limit) throw new InvalidOperationException("That file is larger than allowed.");
        await using var stream = await response.Content.ReadAsStreamAsync(ct).ConfigureAwait(false);
        using var buffer = new MemoryStream();
        var chunk = new byte[81920]; int n;
        while ((n = await stream.ReadAsync(chunk, ct).ConfigureAwait(false)) > 0)
        {
            if (buffer.Length + n > limit) throw new InvalidOperationException("That file is larger than allowed.");
            buffer.Write(chunk, 0, n);
        }
        return buffer.ToArray();
    }

    /// <summary>Text from a downloaded body. A body that is itself gzip (a guide published as .xml.gz) is unpacked, but never past <paramref name="limit"/> bytes: a small file that expands without end is cut off.</summary>
    public static string DecodeBody(ReadOnlySpan<byte> body, long limit)
    {
        if (body.Length < 2 || body[0] != 0x1f || body[1] != 0x8b) return Encoding.UTF8.GetString(body);
        using var gzip = new System.IO.Compression.GZipStream(new MemoryStream(body.ToArray()), System.IO.Compression.CompressionMode.Decompress);
        using var output = new MemoryStream();
        var chunk = new byte[81920]; int n;
        try { while (output.Length < limit && (n = gzip.Read(chunk, 0, chunk.Length)) > 0) output.Write(chunk, 0, (int)Math.Min(n, limit - output.Length)); }
        catch (InvalidDataException) { throw new InvalidOperationException("The downloaded file is damaged."); }
        return Encoding.UTF8.GetString(output.GetBuffer(), 0, (int)output.Length);
    }

    public void Dispose() => _client.Dispose();
}
