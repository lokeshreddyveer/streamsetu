using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace StreamSetu.Core;

// Sync on this network, the same conversation as the Apple and Android apps (docs/WIFI-SYNC.md): a P-256 key per device, ECDH, HKDF-SHA256, AES-256-GCM, six digits compared by the two
// people when a device is new. No server and no account.

public sealed class LanError(string message) : Exception(message);

public static class LanCrypto
{
    public sealed class Identity(ECDiffieHellman key)
    {
        public ECDiffieHellman Key { get; } = key;
        /// <summary>Uncompressed P-256 public key: 04 || X || Y (65 bytes).</summary>
        public byte[] PublicX963 { get { var p = Key.ExportParameters(false); return [0x04, .. p.Q.X!, .. p.Q.Y!]; } }
        public string DeviceId => LanCrypto.DeviceId(PublicX963);
        public static Identity Make() => new(ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256));
        /// <summary>For saving in Credential Manager. Never written to a file.</summary>
        public string Export() => Convert.ToBase64String(Key.ExportPkcs8PrivateKey());
        public static Identity? Import(string? text)
        {
            if (string.IsNullOrEmpty(text)) return null;
            try { var k = ECDiffieHellman.Create(); k.ImportPkcs8PrivateKey(Convert.FromBase64String(text), out _); return new Identity(k); }
            catch (Exception e) when (e is CryptographicException or FormatException) { return null; }
        }
    }

    /// <summary>The first 16 hex characters of SHA-256 of the public key.</summary>
    public static string DeviceId(byte[] publicX963) => Convert.ToHexString(SHA256.HashData(publicX963))[..16].ToLowerInvariant();

    public static byte[] Random(int n) => RandomNumberGenerator.GetBytes(n);

    public static ECDiffieHellmanPublicKey ParsePublic(byte[] x963)
    {
        if (x963.Length != 65 || x963[0] != 0x04) throw new LanError("bad public key");
        var parameters = new ECParameters { Curve = ECCurve.NamedCurves.nistP256, Q = new ECPoint { X = x963[1..33], Y = x963[33..65] } };
        // A point that is not on the curve. Windows reports it as PlatformNotSupportedException (wrapping the real error), other systems as CryptographicException: either way it is a bad key, never a crash.
        try { return ECDiffieHellman.Create(parameters).PublicKey; } catch (Exception e) when (e is CryptographicException or PlatformNotSupportedException or ArgumentException) { throw new LanError("bad public key"); }
    }

    /// <summary>The 32-byte shared secret (the X coordinate), the same value CryptoKit gives.</summary>
    public static byte[] SharedSecret(Identity me, byte[] peerX963) => me.Key.DeriveRawSecretAgreement(ParsePublic(peerX963));

    public static byte[] Hkdf(byte[] ikm, byte[] salt, string info, int length) => HKDF.DeriveKey(HashAlgorithmName.SHA256, ikm, length, salt, Encoding.UTF8.GetBytes(info));

    public static byte[] SessionKey(byte[] z, byte[] nonceInitiator, byte[] nonceResponder) => Hkdf(z, [.. nonceInitiator, .. nonceResponder], "streamsetu-sync-v1 session", 32);

    /// <summary>The six digits both people compare while pairing.</summary>
    public static string ComparisonDigits(byte[] z, byte[] publicInitiator, byte[] publicResponder)
    {
        var b = Hkdf(z, [.. publicInitiator, .. publicResponder], "streamsetu-sync-v1 sas", 4);
        return (BinaryPrimitives.ReadUInt32BigEndian(b) % 1_000_000UL).ToString("D6");
    }

    /// <summary>One direction of an encrypted connection: <c>sending</c> is 0 for what the initiator sends and 1 for what the responder sends. Every frame uses the next counter, so a frame repeated, dropped or reordered fails to open.</summary>
    public sealed class Channel(byte[] key, byte sending)
    {
        private ulong _sent, _received;

        public static byte[] Nonce(byte direction, ulong counter)
        {
            var n = new byte[12]; n[3] = direction;
            BinaryPrimitives.WriteUInt64BigEndian(n.AsSpan(4), counter);
            return n;
        }

        public byte[] Seal(byte[] plain)
        {
            using var aes = new AesGcm(key, 16);
            var cipher = new byte[plain.Length]; var tag = new byte[16];
            aes.Encrypt(Nonce(sending, _sent), plain, cipher, tag);
            _sent++;
            return [.. cipher, .. tag];
        }

        public byte[] Open(byte[] frame)
        {
            if (frame.Length < 16) throw new LanError("bad frame");
            using var aes = new AesGcm(key, 16);
            var plain = new byte[frame.Length - 16];
            try { aes.Decrypt(Nonce((byte)(1 - sending), _received), frame.AsSpan(0, frame.Length - 16), frame.AsSpan(frame.Length - 16), plain); }
            catch (CryptographicException) { throw new LanError("bad frame"); }
            _received++;
            return plain;
        }
    }
}

// ----- Messages -----

public sealed class LanRecord
{
    [JsonPropertyName("k")] public string Kind { get; set; } = "";
    [JsonPropertyName("key")] public List<string> Key { get; set; } = new();
    [JsonPropertyName("ts")] public long Ts { get; set; }
    /// <summary>Written only when true, as the other apps do.</summary>
    [JsonPropertyName("del")] public bool? Del { get; set; }
    [JsonPropertyName("v")] public Dictionary<string, JsonElement>? Value { get; set; }

    [JsonIgnore] public bool Deleted => Del == true;
    [JsonIgnore] public string Identity => Kind + "\u0001" + string.Join("\u0001", Key);

    public static LanRecord Make(string kind, IEnumerable<string> key, long ts, bool deleted = false, Dictionary<string, object?>? value = null)
        => new() { Kind = kind, Key = key.ToList(), Ts = ts, Del = deleted ? true : null, Value = value?.ToDictionary(kv => kv.Key, kv => JsonSerializer.SerializeToElement(kv.Value)) };

    public string? Str(string name) => Value is not null && Value.TryGetValue(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
    public double? Num(string name) => Value is not null && Value.TryGetValue(name, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetDouble(out var d) && double.IsFinite(d) ? d : null;
    public bool? Flag(string name) => Value is not null && Value.TryGetValue(name, out var v) && v.ValueKind is JsonValueKind.True or JsonValueKind.False ? v.GetBoolean() : null;
}

public sealed class LanMessage
{
    [JsonPropertyName("t")] public string T { get; set; } = "";
    [JsonPropertyName("v")] public int? V { get; set; }
    [JsonPropertyName("pub")] public string? Pub { get; set; }
    [JsonPropertyName("name")] public string? Name { get; set; }
    [JsonPropertyName("nonce")] public string? Nonce { get; set; }
    [JsonPropertyName("mode")] public string? Mode { get; set; }
    [JsonPropertyName("why")] public string? Why { get; set; }
    [JsonPropertyName("ok")] public bool? Ok { get; set; }
    [JsonPropertyName("records")] public List<LanRecord>? Records { get; set; }
    [JsonPropertyName("more")] public bool? More { get; set; }
}

public sealed record LanPeer(string Id, string Name, string PublicKey);          // PublicKey: base64 of the 65 bytes

/// <summary>A framed, ordered link: a TCP stream in the app, a pair of pipes in the tests.</summary>
public interface ILanLink
{
    Task SendAsync(byte[] frame, CancellationToken ct = default);
    Task<byte[]> ReceiveAsync(CancellationToken ct = default);
}

public interface ILanTrust
{
    LanPeer? Find(byte[] publicX963);
    void Add(LanPeer peer);
}

public interface ILanData
{
    Task<List<LanRecord>> SnapshotAsync();
    /// <summary>Applies records that arrived, keeping each one only when it is newer than what is here. Returns how many changed something.</summary>
    Task<int> ApplyAsync(IReadOnlyList<LanRecord> records);
}

public abstract record LanOutcome
{
    public sealed record Synced(LanPeer Peer, int Received, bool Paired) : LanOutcome;
    public sealed record Refused(string Why) : LanOutcome;
    public sealed record Failed(string Why) : LanOutcome;
}

/// <summary>4 bytes (big endian) with the length, then the body, at most 8 MiB.</summary>
public sealed class StreamLanLink(Stream stream) : ILanLink
{
    public const int MaxFrame = 8 << 20;

    public async Task SendAsync(byte[] frame, CancellationToken ct = default)
    {
        if (frame.Length > MaxFrame) throw new LanError("bad frame");
        var head = new byte[4]; BinaryPrimitives.WriteUInt32BigEndian(head, (uint)frame.Length);
        await stream.WriteAsync(head, ct).ConfigureAwait(false);
        await stream.WriteAsync(frame, ct).ConfigureAwait(false);
        await stream.FlushAsync(ct).ConfigureAwait(false);
    }

    public async Task<byte[]> ReceiveAsync(CancellationToken ct = default)
    {
        var head = new byte[4]; await ReadExactly(head, ct).ConfigureAwait(false);
        var n = BinaryPrimitives.ReadUInt32BigEndian(head);
        if (n > MaxFrame) throw new LanError("bad frame");
        var body = new byte[n];
        // Read as it arrives: a peer that claims 8 MiB and sends nothing holds only what it has really sent.
        await ReadExactly(body, ct).ConfigureAwait(false);
        return body;
    }

    private async Task ReadExactly(byte[] buffer, CancellationToken ct)
    {
        int got = 0;
        while (got < buffer.Length) { var n = await stream.ReadAsync(buffer.AsMemory(got), ct).ConfigureAwait(false); if (n == 0) throw new LanError("bad frame"); got += n; }
    }
}

/// <summary>The conversation between two devices: hello, a session key, pairing when the other device is new, then one exchange of everything each side has. Written to match LanProtocol.swift.</summary>
public sealed class LanProtocol(LanCrypto.Identity identity, string deviceName, ILanTrust trust, ILanData data, Func<bool> offerPairing, Func<string, string, Task<bool>> confirm, int chunk = 1500)
{
    public const int MaxRecordsPerSync = 500_000;
    private static readonly JsonSerializerOptions Json = new() { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };

    private static byte[] Encode(LanMessage m) => JsonSerializer.SerializeToUtf8Bytes(m, Json);
    private static LanMessage Decode(byte[] b)
    {
        try { return JsonSerializer.Deserialize<LanMessage>(b, Json) ?? throw new LanError("bad message"); }
        catch (JsonException) { throw new LanError("bad message"); }
    }
    private byte[] Hello(byte[] nonce) => Encode(new LanMessage { T = "hello", V = 1, Pub = Convert.ToBase64String(identity.PublicX963), Name = deviceName, Nonce = Convert.ToBase64String(nonce) });

    private static (byte[] Pub, string Name, byte[] Nonce) ReadHello(LanMessage m)
    {
        if (m.T != "hello" || m.Pub is null || m.Name is null || m.Nonce is null) throw new LanError("bad message");
        try { var nonce = Convert.FromBase64String(m.Nonce); if (nonce.Length != 16) throw new LanError("bad message"); return (Convert.FromBase64String(m.Pub), m.Name.Length > 100 ? m.Name[..100] : m.Name, nonce); }
        catch (FormatException) { throw new LanError("bad message"); }
    }

    private async Task SendState(IReadOnlyList<LanRecord> records, ILanLink link, LanCrypto.Channel channel, CancellationToken ct)
    {
        if (records.Count == 0) { await link.SendAsync(channel.Seal(Encode(new LanMessage { T = "state", Records = new(), More = false })), ct); return; }
        for (int start = 0; start < records.Count; start += chunk)
        {
            var end = Math.Min(start + chunk, records.Count);
            await link.SendAsync(channel.Seal(Encode(new LanMessage { T = "state", Records = records.Skip(start).Take(end - start).ToList(), More = end < records.Count })), ct);
        }
    }

    private async Task<int> ReceiveState(ILanLink link, LanCrypto.Channel channel, CancellationToken ct)
    {
        int received = 0, total = 0;
        while (true)
        {
            var m = Decode(channel.Open(await link.ReceiveAsync(ct)));
            if (m.T != "state") throw new LanError("unexpected message");
            total += m.Records?.Count ?? 0;
            if (total > MaxRecordsPerSync) throw new LanError("too many records");
            received += await data.ApplyAsync(m.Records ?? new());
            if (m.More != true) return received;
        }
    }

    public async Task<LanOutcome> RunInitiatorAsync(ILanLink link, CancellationToken ct = default)
    {
        try
        {
            var nonce = LanCrypto.Random(16);
            await link.SendAsync(Hello(nonce), ct);
            var (peerPub, peerName, peerNonce) = ReadHello(Decode(await link.ReceiveAsync(ct)));
            var z = LanCrypto.SharedSecret(identity, peerPub);
            var channel = new LanCrypto.Channel(LanCrypto.SessionKey(z, nonce, peerNonce), 0);
            var known = trust.Find(peerPub);
            await link.SendAsync(channel.Seal(Encode(new LanMessage { T = "start", Mode = known is null ? "pair" : "sync" })), ct);
            var peer = known ?? new LanPeer(LanCrypto.DeviceId(peerPub), peerName, Convert.ToBase64String(peerPub));
            bool paired = false;
            var first = Decode(channel.Open(await link.ReceiveAsync(ct)));
            switch (first.T)
            {
                case "reject": return new LanOutcome.Refused(first.Why ?? "refused");
                case "pair":
                {
                    var digits = LanCrypto.ComparisonDigits(z, identity.PublicX963, peerPub);
                    var ok = await confirm(digits, peerName);
                    await link.SendAsync(channel.Seal(Encode(new LanMessage { T = "pair", Ok = ok })), ct);
                    var theirs = Decode(channel.Open(await link.ReceiveAsync(ct)));
                    if (!ok || theirs.Ok != true) return new LanOutcome.Refused("not confirmed");
                    trust.Add(peer); paired = true;
                    break;
                }
                case "ready": break;
                default: return new LanOutcome.Failed("unexpected answer");
            }
            await SendState(await data.SnapshotAsync(), link, channel, ct);
            var received = await ReceiveState(link, channel, ct);
            await link.SendAsync(channel.Seal(Encode(new LanMessage { T = "bye" })), ct);
            return new LanOutcome.Synced(peer, received, paired);
        }
        catch (Exception e) when (e is LanError or JsonException or CryptographicException or PlatformNotSupportedException or IOException or OperationCanceledException or FormatException) { return new LanOutcome.Failed(e.Message); }
    }

    public async Task<LanOutcome> RunResponderAsync(ILanLink link, CancellationToken ct = default)
    {
        try
        {
            var (peerPub, peerName, peerNonce) = ReadHello(Decode(await link.ReceiveAsync(ct)));
            var nonce = LanCrypto.Random(16);
            await link.SendAsync(Hello(nonce), ct);
            var z = LanCrypto.SharedSecret(identity, peerPub);
            var channel = new LanCrypto.Channel(LanCrypto.SessionKey(z, peerNonce, nonce), 1);
            var start = Decode(channel.Open(await link.ReceiveAsync(ct)));
            var known = trust.Find(peerPub);
            var peer = known ?? new LanPeer(LanCrypto.DeviceId(peerPub), peerName, Convert.ToBase64String(peerPub));
            bool paired = false;
            if (start.Mode == "pair" || known is null)
            {
                if (!offerPairing())
                {
                    await link.SendAsync(channel.Seal(Encode(new LanMessage { T = "reject", Why = "not-paired" })), ct);
                    return new LanOutcome.Refused("not paired");
                }
                await link.SendAsync(channel.Seal(Encode(new LanMessage { T = "pair" })), ct);
                var digits = LanCrypto.ComparisonDigits(z, peerPub, identity.PublicX963);
                var ok = await confirm(digits, peerName);
                var theirs = Decode(channel.Open(await link.ReceiveAsync(ct)));
                await link.SendAsync(channel.Seal(Encode(new LanMessage { T = "pair", Ok = ok })), ct);
                if (!ok || theirs.Ok != true) return new LanOutcome.Refused("not confirmed");
                trust.Add(peer); paired = true;
            }
            else await link.SendAsync(channel.Seal(Encode(new LanMessage { T = "ready" })), ct);
            var received = await ReceiveState(link, channel, ct);
            await SendState(await data.SnapshotAsync(), link, channel, ct);
            var bye = Decode(channel.Open(await link.ReceiveAsync(ct)));
            return bye.T == "bye" ? new LanOutcome.Synced(peer, received, paired) : new LanOutcome.Failed("unexpected message");
        }
        catch (Exception e) when (e is LanError or JsonException or CryptographicException or PlatformNotSupportedException or IOException or OperationCanceledException or FormatException) { return new LanOutcome.Failed(e.Message); }
    }
}

/// <summary>The devices this one has been paired with: public keys and names only, nothing secret.</summary>
public sealed class LanTrustStore(LocalStore store) : ILanTrust
{
    private List<LanPeer> Load() => store.Load("LanTrust", new List<LanPeer>());
    public List<LanPeer> All() => Load();
    public LanPeer? Find(byte[] publicX963) { var key = Convert.ToBase64String(publicX963); return Load().FirstOrDefault(p => p.PublicKey == key); }
    public void Add(LanPeer peer) { var l = Load(); l.RemoveAll(p => p.Id == peer.Id); l.Add(peer); store.Save("LanTrust", l); }
    public void Remove(string id) { var l = Load(); if (l.RemoveAll(p => p.Id == id) > 0) store.Save("LanTrust", l); }
}

/// <summary>The key that stands for a playlist on every device: the first 16 hex characters of SHA-256 of its address, lower-cased, without http(s):// and without trailing slashes.</summary>
public static class LanSourceKey
{
    public static string Of(string address)
    {
        var a = address.Trim().ToLowerInvariant();
        foreach (var prefix in new[] { "https://", "http://" }) if (a.StartsWith(prefix, StringComparison.Ordinal)) { a = a[prefix.Length..]; break; }
        a = a.TrimEnd('/');
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(a)))[..16].ToLowerInvariant();
    }
}

/// <summary>Favorites, resume points and collections as records for another device, and the records that come back as changes here. Each change is remembered with the time it was seen (a "shadow" of what was last in step),
/// so a removal can be sent as a removal, and a change that is not newer than what is here is ignored.</summary>
public sealed class LanSyncData(LocalStore user, IReadOnlyList<Playlist> playlists, Func<long>? nowMs = null) : ILanData
{
    private sealed record Seen(long Ts, bool Deleted, string Sig);
    private readonly Func<long> _now = nowMs ?? (() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
    private readonly object _gate = new();
    private readonly Collections _collections = new(user);

    private static readonly Dictionary<string, string> LocalToWire = new() { ["live"] = "channel", ["movie"] = "movie", ["series"] = "series", ["episode"] = "episode" };
    private static readonly Dictionary<string, string> WireToLocal = LocalToWire.ToDictionary(kv => kv.Value, kv => kv.Key);

    private Dictionary<string, string> KeyOfPlaylist() => playlists.Where(p => p.Kind != PlaylistKind.LocalFolder).GroupBy(p => p.Id).ToDictionary(g => g.Key, g => LanSourceKey.Of(g.First().Address));
    private Dictionary<string, string> PlaylistOfKey() { var d = new Dictionary<string, string>(); foreach (var p in playlists) d.TryAdd(LanSourceKey.Of(p.Address), p.Id); return d; }

    /// <summary>"playlistId|live:5" to [sourceKey, "channel", "5"], or null for an item that cannot be named on other devices (an M3U entry has no stable id).</summary>
    private static List<string>? Wire(string localKey, Dictionary<string, string> keyOf)
    {
        var bar = localKey.IndexOf('|'); if (bar <= 0) return null;
        var colon = localKey.IndexOf(':', bar); if (colon < 0) return null;
        var kind = localKey[(bar + 1)..colon]; var provider = localKey[(colon + 1)..];
        return provider.Length > 0 && LocalToWire.TryGetValue(kind, out var w) && keyOf.TryGetValue(localKey[..bar], out var sk) ? new List<string> { sk, w, provider } : null;
    }

    private static string? Local(IReadOnlyList<string> wire, Dictionary<string, string> playlistOf)
        => wire.Count >= 3 && playlistOf.TryGetValue(wire[0], out var pid) && WireToLocal.TryGetValue(wire[1], out var kind) && wire[2].Length > 0 && !wire[2].Contains('|') ? $"{pid}|{kind}:{wire[2]}" : null;

    private Dictionary<string, Seen> LoadSeen() => user.Load("LanLog", new Dictionary<string, Seen>());

    /// <summary>What this device has now, as records with their times. Things that appeared or changed since the last look are stamped now; things that disappeared become removals.</summary>
    private List<LanRecord> Refresh(Dictionary<string, Seen> seen, long now)
    {
        var keyOf = KeyOfPlaylist(); var current = new Dictionary<string, (LanRecord Record, string Sig)>();
        void Put(LanRecord r, string sig) => current[r.Identity] = (r, sig);

        foreach (var fav in user.Favorites()) if (Wire(fav, keyOf) is { } w) Put(LanRecord.Make("fav", [.. w, "favorites"], 0, value: new() { ["at"] = now }), "");
        var watched = user.Watched();
        foreach (var kv in user.RecentProgress())
            if (Wire(kv.Key, keyOf) is { } w && !watched.Contains(kv.Key))
                Put(LanRecord.Make("prog", w, 0, value: new() { ["pos"] = Math.Round(kv.Value.Position, 1), ["dur"] = Math.Round(kv.Value.Duration, 1), ["done"] = false }), $"{(long)kv.Value.Position / 5}|false");
        foreach (var key in watched) if (Wire(key, keyOf) is { } w) Put(LanRecord.Make("prog", w, 0, value: new() { ["pos"] = 0.0, ["dur"] = 0.0, ["done"] = true }), "|true");
        foreach (var c in _collections.All())
        {
            Put(LanRecord.Make("col", [c.Id], 0, value: new() { ["name"] = c.Name, ["scope"] = "movie" }), c.Name);
            foreach (var k in c.Keys) if (Wire(k, keyOf) is { } w) Put(LanRecord.Make("colitem", [c.Id, .. w], 0, value: new() { ["at"] = now }), "");
        }

        var output = new List<LanRecord>();
        foreach (var (id, (record, sig)) in current)
        {
            if (seen.TryGetValue(id, out var s) && !s.Deleted && s.Sig == sig) record.Ts = s.Ts;
            else { record.Ts = now; seen[id] = new Seen(now, false, sig); }
            output.Add(record);
        }
        // Gone since last time: a removal, but only for a playlist this device still has (a playlist that was removed is not a removal of its favorites on other devices).
        foreach (var (id, s) in seen.ToList())
        {
            if (current.ContainsKey(id) || s.Deleted) { if (!current.ContainsKey(id) && s.Deleted) output.Add(Tombstone(id, s.Ts)); continue; }
            var parts = id.Split('\u0001'); var kind = parts[0]; var key = parts.Skip(1).ToList();
            var sourceKey = kind == "colitem" ? key.ElementAtOrDefault(1) : kind == "col" ? null : key.FirstOrDefault();
            if (sourceKey is not null && !keyOf.ContainsValue(sourceKey)) continue;
            seen[id] = new Seen(now, true, ""); output.Add(Tombstone(id, now));
        }
        return output;
    }

    private static LanRecord Tombstone(string id, long ts) { var parts = id.Split('\u0001'); return LanRecord.Make(parts[0], parts.Skip(1), ts, deleted: true); }

    public Task<List<LanRecord>> SnapshotAsync()
    {
        lock (_gate) { var seen = LoadSeen(); var records = Refresh(seen, _now()); user.Save("LanLog", seen); return Task.FromResult(records); }
    }

    public Task<int> ApplyAsync(IReadOnlyList<LanRecord> records)
    {
        lock (_gate)
        {
            var seen = LoadSeen(); Refresh(seen, _now());                       // make sure everything here has a time first, so "newer" means something
            var playlistOf = PlaylistOfKey(); int applied = 0;
            var order = new Dictionary<string, int> { ["col"] = 0, ["fav"] = 1, ["prog"] = 1, ["colitem"] = 2 };
            foreach (var r in records.Where(r => order.ContainsKey(r.Kind)).OrderBy(r => order[r.Kind]).ThenBy(r => r.Deleted ? 1 : 0))
                if (ApplyOne(r, seen, playlistOf)) applied++;
            user.Save("LanLog", seen);
            return Task.FromResult(applied);
        }
    }

    private bool ApplyOne(LanRecord r, Dictionary<string, Seen> seen, Dictionary<string, string> playlistOf)
    {
        if (r.Key.Count > 8 || r.Key.Any(k => k.Length > 200)) return false;
        string sig = "";
        switch (r.Kind)
        {
            case "fav":
            {
                if (r.Key.Count != 4 || r.Key[3] != "favorites" || Local(r.Key, playlistOf) is not { } id) return false;
                if (!Newer(seen, r)) return false;
                if (r.Deleted) user.RemoveFavorite(id); else user.AddFavorite(id);
                break;
            }
            case "prog":
            {
                if (r.Key.Count != 3 || Local(r.Key, playlistOf) is not { } id) return false;
                if (!Newer(seen, r)) return false;
                if (r.Deleted) { user.ClearProgress(id); user.MarkUnwatched(id); }
                else if (r.Flag("done") == true) { user.ClearProgress(id); user.MarkWatched(id); sig = "|true"; }
                else
                {
                    var pos = Math.Max(0, r.Num("pos") ?? 0); var dur = Math.Max(0, r.Num("dur") ?? 0);
                    user.MarkUnwatched(id); user.SetProgress(id, pos, dur, r.Ts); sig = $"{(long)pos / 5}|false";            // the same form Refresh uses, so a received position is not mistaken for a local change
                }
                break;
            }
            case "col":
            {
                if (r.Key.Count != 1 || r.Key[0] == "watch-later") return false;
                if (!Newer(seen, r)) return false;
                if (r.Deleted) _collections.Delete(r.Key[0]); else { _collections.Upsert(r.Key[0], r.Str("name") ?? "Collection"); sig = (r.Str("name") ?? "Collection").Trim(); }
                break;
            }
            case "colitem":
            {
                if (r.Key.Count != 4 || r.Key[0] == "watch-later" || Local(r.Key.Skip(1).ToList(), playlistOf) is not { } id) return false;
                if (!Newer(seen, r)) return false;
                if (r.Deleted) _collections.Remove(r.Key[0], id);
                else { if (!_collections.All().Any(c => c.Id == r.Key[0])) _collections.Upsert(r.Key[0], "Collection"); _collections.Add(r.Key[0], id); }
                break;
            }
            default: return false;
        }
        seen[r.Identity] = new Seen(r.Ts, r.Deleted, sig);
        return true;
    }

    /// <summary>Only a strictly newer change replaces what is here, so the same state sent back and forth settles.</summary>
    private static bool Newer(Dictionary<string, Seen> seen, LanRecord r) => !seen.TryGetValue(r.Identity, out var s) || r.Ts > s.Ts;
}

/// <summary>One stream made of a stream to read from and a stream to write to (Windows sockets give the two separately).</summary>
public sealed class DuplexStream(Stream input, Stream output) : Stream
{
    public override bool CanRead => true;
    public override bool CanWrite => true;
    public override bool CanSeek => false;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override int Read(byte[] buffer, int offset, int count) => input.Read(buffer, offset, count);
    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default) => input.ReadAsync(buffer, ct);
    public override void Write(byte[] buffer, int offset, int count) => output.Write(buffer, offset, count);
    public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken ct = default) => output.WriteAsync(buffer, ct);
    public override void Flush() => output.Flush();
    public override Task FlushAsync(CancellationToken ct) => output.FlushAsync(ct);
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    protected override void Dispose(bool disposing) { if (disposing) { input.Dispose(); output.Dispose(); } base.Dispose(disposing); }
}
