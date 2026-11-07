using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Text;

namespace StreamSetu.Core;

/// <summary>Looks a host name up. The default asks the system; <see cref="DohResolver"/> asks an encrypted DNS server instead, for StreamSetu only (no VPN, no system change).</summary>
public interface IHostResolver { Task<IPAddress[]> ResolveAsync(string host, CancellationToken ct); }

public sealed class SystemResolver : IHostResolver
{
    public Task<IPAddress[]> ResolveAsync(string host, CancellationToken ct) => Dns.GetHostAddressesAsync(host, ct);
}

public static class DnsWire
{
    public const int TypeA = 1, TypeAaaa = 28;

    public static byte[] BuildQuery(string host, int type, ushort id = 0)
    {
        var ms = new MemoryStream();
        Span<byte> header = stackalloc byte[12]; header.Clear();
        BinaryPrimitives.WriteUInt16BigEndian(header, id); BinaryPrimitives.WriteUInt16BigEndian(header[2..], 0x0100); BinaryPrimitives.WriteUInt16BigEndian(header[4..], 1);
        ms.Write(header);
        foreach (var label in new System.Globalization.IdnMapping().GetAscii(host.TrimEnd('.')).Split('.'))
        {
            var bytes = Encoding.ASCII.GetBytes(label);
            if (bytes.Length is 0 or > 63) throw new ArgumentException("Not a valid host name.");
            ms.WriteByte((byte)bytes.Length); ms.Write(bytes);
        }
        ms.WriteByte(0);
        Span<byte> tail = stackalloc byte[4];
        BinaryPrimitives.WriteUInt16BigEndian(tail, (ushort)type); BinaryPrimitives.WriteUInt16BigEndian(tail[2..], 1);
        ms.Write(tail);
        return ms.ToArray();
    }

    /// <summary>Skips a name (labels, or a pointer that ends it). Returns the position after it, or -1 when the data is cut off or wrong. Pointers are not followed: only the position is needed.</summary>
    private static int SkipName(ReadOnlySpan<byte> m, int pos)
    {
        for (int hops = 0; hops < 128; hops++)
        {
            if (pos >= m.Length) return -1;
            var len = m[pos];
            if (len == 0) return pos + 1;
            if ((len & 0xC0) == 0xC0) return pos + 2 <= m.Length ? pos + 2 : -1;
            if ((len & 0xC0) != 0) return -1;
            pos += 1 + len;
        }
        return -1;
    }

    /// <summary>The addresses in an answer. Anything cut off, inconsistent or of another kind is skipped; an error code gives an empty list. Never throws on bad data.</summary>
    public static List<IPAddress> ParseAnswer(ReadOnlySpan<byte> m)
    {
        var result = new List<IPAddress>();
        if (m.Length < 12 || (BinaryPrimitives.ReadUInt16BigEndian(m[2..]) & 0x000F) != 0) return result;
        int questions = BinaryPrimitives.ReadUInt16BigEndian(m[4..]), answers = BinaryPrimitives.ReadUInt16BigEndian(m[6..]);
        int pos = 12;
        for (int i = 0; i < questions; i++) { pos = SkipName(m, pos); if (pos < 0 || pos + 4 > m.Length) return result; pos += 4; }
        for (int i = 0; i < Math.Min(answers, 64); i++)
        {
            pos = SkipName(m, pos);
            if (pos < 0 || pos + 10 > m.Length) return result;
            int type = BinaryPrimitives.ReadUInt16BigEndian(m[pos..]), length = BinaryPrimitives.ReadUInt16BigEndian(m[(pos + 8)..]);
            pos += 10;
            if (pos + length > m.Length) return result;
            if ((type == TypeA && length == 4) || (type == TypeAaaa && length == 16)) result.Add(new IPAddress(m.Slice(pos, length)));
            pos += length;
        }
        return result;
    }
}

public sealed record DnsProvider(string Name, string Url)
{
    // The addresses are written as numbers, so looking up the DNS server's own name never needs the system DNS this is meant to replace.
    public static readonly DnsProvider Cloudflare = new("Cloudflare", "https://1.1.1.1/dns-query");
    public static readonly DnsProvider Google = new("Google", "https://8.8.8.8/dns-query");
    public static readonly DnsProvider Quad9 = new("Quad9", "https://9.9.9.9/dns-query");
    public static readonly IReadOnlyList<DnsProvider> Presets = new[] { Cloudflare, Google, Quad9 };

    public static DnsProvider? Custom(string url) => Uri.TryCreate(url.Trim(), UriKind.Absolute, out var u) && u.Scheme == Uri.UriSchemeHttps ? new DnsProvider("Custom", u.AbsoluteUri) : null;
}

/// <summary>DNS over HTTPS (RFC 8484). Answers are cached for five minutes, and a failure falls back to the system so a DNS provider outage never stops the app.</summary>
public sealed class DohResolver(DnsProvider provider, HttpClient http, IHostResolver? fallback = null, Func<DateTimeOffset>? now = null) : IHostResolver
{
    private readonly Dictionary<string, (DateTimeOffset Until, IPAddress[] Addresses)> _cache = new(StringComparer.OrdinalIgnoreCase);
    private readonly Func<DateTimeOffset> _now = now ?? (() => DateTimeOffset.UtcNow);
    private readonly IHostResolver _fallback = fallback ?? new SystemResolver();

    public async Task<IPAddress[]> ResolveAsync(string host, CancellationToken ct)
    {
        if (IPAddress.TryParse(host.Trim('[', ']'), out var literal)) return new[] { literal };
        lock (_cache) if (_cache.TryGetValue(host, out var hit) && hit.Until > _now()) return hit.Addresses;
        try
        {
            var both = await Task.WhenAll(Ask(host, DnsWire.TypeA, ct), Ask(host, DnsWire.TypeAaaa, ct)).ConfigureAwait(false);
            var all = both.SelectMany(x => x).Distinct().ToArray();
            if (all.Length > 0) { lock (_cache) _cache[host] = (_now().AddMinutes(5), all); return all; }
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or ArgumentException or InvalidOperationException && !ct.IsCancellationRequested) { }
        return await _fallback.ResolveAsync(host, ct).ConfigureAwait(false);
    }

    private async Task<List<IPAddress>> Ask(string host, int type, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, provider.Url) { Content = new ByteArrayContent(DnsWire.BuildQuery(host, type)) };
        request.Content.Headers.ContentType = new("application/dns-message");
        request.Headers.Accept.ParseAdd("application/dns-message");
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        var bytes = await response.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
        return bytes.Length > 4096 ? new() : DnsWire.ParseAnswer(bytes);
    }
}
