using System.Security.Cryptography;
using System.Text;
using System.Threading.Channels;
using StreamSetu.Core;
using Xunit;

namespace StreamSetu.Core.Tests;

public sealed class LanSyncTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "streamsetu-test-" + Guid.NewGuid().ToString("N"));
    public void Dispose() { try { Directory.Delete(_dir, true); } catch (IOException) { } }

    // ---------- Interoperability: values produced by the Mac app's own CryptoKit code (see Services/LanSync/LanCrypto.swift) ----------

    private const string PubA = "04515c3d6eb9e396b904d3feca7f54fdcd0cc1e997bf375dca515ad0a6c3b4035f4536be3a50f318fbf9a5475902a221502bef0d57e08c53b2cc0a56f17d9f9354";
    private const string PubB = "041f140146bfb1b251f84f4ddbe0d4cdcfd77afd984a9520e35794021f8312bb9eec995a08b1fa7704df3dcc0b50a9665263fb7711f95f9f8a449c5096e47c892b";
    private const string Z = "4fe243908f378aa1c2a69538822e6ed908c3225d8692575507c649901245150a";
    private const string K = "84788b60b278e81599b347c6ef674852790669f6ac5ba7a07a07b814a1681655";

    private static byte[] H(string hex) => Convert.FromHexString(hex);
    private static string X(byte[] b) => Convert.ToHexString(b).ToLowerInvariant();

    private static LanCrypto.Identity FromPrivate(byte[] d, string pubHex)
    {
        var pub = H(pubHex);
        return new LanCrypto.Identity(ECDiffieHellman.Create(new ECParameters { Curve = ECCurve.NamedCurves.nistP256, D = d, Q = new ECPoint { X = pub[1..33], Y = pub[33..65] } }));
    }

    private static readonly byte[] DA = Enumerable.Range(1, 32).Select(i => (byte)i).ToArray(), DB = Enumerable.Range(33, 32).Select(i => (byte)i).ToArray();
    private static readonly byte[] NonceI = Enumerable.Range(0, 16).Select(i => (byte)i).ToArray(), NonceR = Enumerable.Range(16, 16).Select(i => (byte)i).ToArray();

    [Fact]
    public void Our_crypto_gives_the_same_secret_key_digits_and_frames_as_the_Mac_app()
    {
        var a = FromPrivate(DA, PubA); var b = FromPrivate(DB, PubB);
        Assert.Equal(PubA, X(a.PublicX963)); Assert.Equal("4269889431e31319", a.DeviceId);
        Assert.Equal(Z, X(LanCrypto.SharedSecret(a, b.PublicX963))); Assert.Equal(Z, X(LanCrypto.SharedSecret(b, a.PublicX963)));
        var key = LanCrypto.SessionKey(H(Z), NonceI, NonceR); Assert.Equal(K, X(key));
        Assert.Equal("312114", LanCrypto.ComparisonDigits(H(Z), a.PublicX963, b.PublicX963));
        var initiator = new LanCrypto.Channel(key, 0);
        Assert.Equal("74fa5d962addeda7aca9736ec2b1d88c5d572b1bc0d675a0d3636c4edd", X(initiator.Seal(Encoding.UTF8.GetBytes("{\"t\":\"hello\"}"))));
        Assert.Equal("a50447a7a6e079dd121568202237d46bdb9114cfd7ab", X(initiator.Seal(Encoding.UTF8.GetBytes("second"))));           // the counter moved on
        Assert.Equal("fb81feba795c510ad1d4b8d5f4f380d28e10793a3c", X(new LanCrypto.Channel(key, 1).Seal(Encoding.UTF8.GetBytes("reply"))));
        var responder = new LanCrypto.Channel(key, 1);                                                      // and the Mac's frames open here
        Assert.Equal("{\"t\":\"hello\"}", Encoding.UTF8.GetString(responder.Open(H("74fa5d962addeda7aca9736ec2b1d88c5d572b1bc0d675a0d3636c4edd"))));
        Assert.Equal("second", Encoding.UTF8.GetString(responder.Open(H("a50447a7a6e079dd121568202237d46bdb9114cfd7ab"))));
    }

    [Fact]
    public void A_frame_cannot_be_replayed_reordered_tampered_with_or_turned_around()
    {
        var key = LanCrypto.Random(32);
        var send = new LanCrypto.Channel(key, 0); var f0 = send.Seal([1, 2, 3]); var f1 = send.Seal([4, 5, 6]);
        var recv = new LanCrypto.Channel(key, 1);
        Assert.Throws<LanError>(() => recv.Open(f1));                                                      // out of order
        Assert.Equal(new byte[] { 1, 2, 3 }, recv.Open(f0)); Assert.Throws<LanError>(() => recv.Open(f0));           // replayed
        Assert.Equal(new byte[] { 4, 5, 6 }, recv.Open(f1));
        var tampered = send.Seal([9, 9]); tampered[0] ^= 1; Assert.Throws<LanError>(() => new LanCrypto.Channel(key, 1).Open(tampered));
        Assert.Throws<LanError>(() => new LanCrypto.Channel(key, 0).Open(new LanCrypto.Channel(key, 0).Seal([1])));  // a device's own frame sent back to it
        Assert.Throws<LanError>(() => new LanCrypto.Channel(key, 1).Open([1, 2, 3]));                      // shorter than a tag
    }

    [Fact]
    public void A_public_key_that_is_not_a_point_on_the_curve_is_refused()
    {
        Assert.Throws<LanError>(() => LanCrypto.ParsePublic(new byte[65]));
        Assert.Throws<LanError>(() => LanCrypto.ParsePublic(H(PubA)[..64]));
        var offCurve = H(PubA); offCurve[64] ^= 1;
        Assert.Throws<LanError>(() => LanCrypto.ParsePublic(offCurve));
    }

    [Fact]
    public void A_device_key_survives_being_saved_and_loaded()
    {
        var id = LanCrypto.Identity.Make(); var back = LanCrypto.Identity.Import(id.Export())!;
        Assert.Equal(id.PublicX963, back.PublicX963); Assert.Null(LanCrypto.Identity.Import("not base64!")); Assert.Null(LanCrypto.Identity.Import(null));
    }

    // ---------- Framing ----------

    [Fact]
    public async Task Frames_round_trip_and_an_oversized_or_cut_off_frame_is_refused()
    {
        var ms = new MemoryStream(); var link = new StreamLanLink(ms);
        await link.SendAsync([1, 2, 3]); await link.SendAsync([]); ms.Position = 0;
        Assert.Equal(new byte[] { 1, 2, 3 }, await link.ReceiveAsync()); Assert.Empty(await link.ReceiveAsync());
        await Assert.ThrowsAsync<LanError>(() => new StreamLanLink(new MemoryStream([0, 0x80, 0, 1])).ReceiveAsync());        // claims 8 MiB + 1
        await Assert.ThrowsAsync<LanError>(() => new StreamLanLink(new MemoryStream([0, 0, 0, 10, 1, 2])).ReceiveAsync());    // promises 10, sends 2
        await Assert.ThrowsAsync<LanError>(() => new StreamLanLink(new MemoryStream([0, 0])).ReceiveAsync());
    }

    // ---------- The conversation between two devices ----------

    private sealed class PipeLink(ChannelReader<byte[]> input, ChannelWriter<byte[]> output) : ILanLink
    {
        public Func<byte[], byte[]>? Tamper;
        public Task SendAsync(byte[] frame, CancellationToken ct = default) { output.TryWrite(Tamper?.Invoke(frame) ?? frame); return Task.CompletedTask; }
        public async Task<byte[]> ReceiveAsync(CancellationToken ct = default)
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct); timeout.CancelAfter(TimeSpan.FromSeconds(5));
            return await input.ReadAsync(timeout.Token);
        }
    }

    private static (PipeLink A, PipeLink B) Pipe()
    {
        var ab = Channel.CreateUnbounded<byte[]>(); var ba = Channel.CreateUnbounded<byte[]>();
        return (new PipeLink(ba.Reader, ab.Writer), new PipeLink(ab.Reader, ba.Writer));
    }

    private sealed class MemoryTrust : ILanTrust
    {
        public readonly List<LanPeer> Peers = new();
        public LanPeer? Find(byte[] pub) => Peers.FirstOrDefault(p => p.PublicKey == Convert.ToBase64String(pub));
        public void Add(LanPeer p) { Peers.RemoveAll(x => x.Id == p.Id); Peers.Add(p); }
    }

    private sealed class Device
    {
        public readonly LocalStore User; public readonly Playlist Playlist; public readonly MemoryTrust Trust = new(); public readonly LanCrypto.Identity Identity = LanCrypto.Identity.Make();
        public long Clock; public readonly string Name;
        public bool Offers = true, Confirms = true; public string? SeenDigits;
        public Device(string dir, string name, string playlistId, long clock)
        {
            Name = name; Clock = clock; User = new LocalStore(Path.Combine(dir, name));
            Playlist = new Playlist(playlistId, "Panel", PlaylistKind.Xtream, "http://panel.example:8080", "u", "playlist:" + playlistId);
        }
        public LanSyncData Data => new(User, [Playlist], () => Clock);
        public LanProtocol Protocol(ILanTrust? trust = null) => new(Identity, Name, trust ?? Trust, Data, () => Offers, (digits, _) => { SeenDigits = digits; return Task.FromResult(Confirms); });
        public string Key(string id) => Playlist.Id + "|" + id;
    }

    private static async Task<(LanOutcome Initiator, LanOutcome Responder)> Sync(Device initiator, Device responder, Action<PipeLink, PipeLink>? tamper = null)
    {
        var (a, b) = Pipe(); tamper?.Invoke(a, b);
        var r = responder.Protocol().RunResponderAsync(b); var i = initiator.Protocol().RunInitiatorAsync(a);
        return (await i, await r);
    }

    [Fact]
    public async Task Two_new_devices_pair_with_the_same_six_digits_and_then_keep_favorites_resume_points_and_collections_in_step()
    {
        var a = new Device(_dir, "a", "pidA", 1000); var b = new Device(_dir, "b", "pidB", 500);        // the same panel under different local ids
        a.User.ToggleFavorite(a.Key("movie:9")); a.User.ToggleFavorite(a.Key("live:5")); a.User.ToggleFavorite(a.Key("m3u:3"));
        a.User.SetProgress(a.Key("movie:9"), 600, 7200, 1000); a.User.MarkWatched(a.Key("episode:20"));
        var cols = new Collections(a.User); var c = cols.Create("Heists"); cols.Add(c.Id, a.Key("movie:9"));

        var (first, second) = await Sync(a, b);
        var synced = Assert.IsType<LanOutcome.Synced>(first); Assert.True(synced.Paired); Assert.IsType<LanOutcome.Synced>(second);
        Assert.Equal(a.SeenDigits, b.SeenDigits); Assert.Matches(@"^\d{6}$", a.SeenDigits!);
        Assert.Single(a.Trust.Peers); Assert.Single(b.Trust.Peers);

        Assert.Equal(new[] { b.Key("live:5"), b.Key("movie:9") }.OrderBy(x => x), b.User.Favorites().OrderBy(x => x));          // the M3U entry has no stable id and is not sent
        Assert.Equal(600, b.User.ProgressOf(b.Key("movie:9"))?.Position); Assert.Contains(b.Key("episode:20"), b.User.Watched());
        var theirs = new Collections(b.User).All().Single(); Assert.Equal("Heists", theirs.Name); Assert.Equal(c.Id, theirs.Id); Assert.Equal(new[] { b.Key("movie:9") }, theirs.Keys);

        // Already paired: straight to syncing, no digits.
        a.SeenDigits = null; var (again, _) = await Sync(a, b);
        Assert.False(Assert.IsType<LanOutcome.Synced>(again).Paired); Assert.Null(a.SeenDigits);
    }

    [Fact]
    public async Task A_removal_travels_and_the_newer_change_wins_in_both_directions()
    {
        var a = new Device(_dir, "a", "pidA", 1000); var b = new Device(_dir, "b", "pidB", 1000);
        a.User.ToggleFavorite(a.Key("movie:1")); a.User.ToggleFavorite(a.Key("movie:2"));
        await Sync(a, b);
        Assert.Equal(2, b.User.Favorites().Count);

        a.Clock = 2000; a.User.ToggleFavorite(a.Key("movie:1"));                                           // removed on A
        b.Clock = 3000; b.User.SetProgress(b.Key("movie:2"), 300, 7000, 3000);                              // progress on B
        a.Clock = 2500; a.User.SetProgress(a.Key("movie:2"), 100, 7000, 2500);                              // older progress on A
        await Sync(a, b);
        Assert.Equal(new[] { b.Key("movie:2") }, b.User.Favorites()); Assert.Equal(new[] { a.Key("movie:2") }, a.User.Favorites());
        Assert.Equal(300, a.User.ProgressOf(a.Key("movie:2"))?.Position); Assert.Equal(300, b.User.ProgressOf(b.Key("movie:2"))?.Position);      // B's was newer

        await Sync(b, a);                                                                                   // already equal: nothing flips back
        Assert.Equal(new[] { a.Key("movie:2") }, a.User.Favorites());
    }

    [Fact]
    public async Task A_removed_collection_and_a_finished_title_travel_too()
    {
        var a = new Device(_dir, "a", "pidA", 1000); var b = new Device(_dir, "b", "pidB", 1000);
        var cols = new Collections(a.User); var c = cols.Create("Temp"); cols.Add(c.Id, a.Key("series:4")); a.User.SetProgress(a.Key("episode:7"), 100, 2000, 1000);
        await Sync(a, b);
        Assert.Single(new Collections(b.User).All());
        a.Clock = 2000; cols.Delete(c.Id); a.User.SaveProgress(a.Key("episode:7"), 1990, 2000);            // collection deleted; episode finished
        await Sync(a, b);
        Assert.Empty(new Collections(b.User).All()); Assert.Null(b.User.ProgressOf(b.Key("episode:7"))); Assert.Contains(b.Key("episode:7"), b.User.Watched());
    }

    [Fact]
    public async Task Things_of_a_connection_this_device_does_not_have_are_ignored_and_not_removed_from_the_other()
    {
        var a = new Device(_dir, "a", "pidA", 1000);
        var other = new Device(_dir, "b", "pidB", 1000) ; // same panel; now give B a different panel only
        var b = new Device(_dir, "c", "pidC", 1000);
        var differentPanel = new Playlist("pidC", "Other", PlaylistKind.Xtream, "http://other.example:9090", "u", "playlist:pidC");
        a.User.ToggleFavorite(a.Key("movie:1"));
        var bData = new LanSyncData(b.User, [differentPanel], () => 1000);
        var proto = new LanProtocol(b.Identity, "c", b.Trust, bData, () => true, (_, _) => Task.FromResult(true));
        var (la, lb) = Pipe();
        var r = proto.RunResponderAsync(lb); var i = a.Protocol().RunInitiatorAsync(la);
        Assert.IsType<LanOutcome.Synced>(await i); await r;
        Assert.Empty(b.User.Favorites());                                                                  // nothing applied for a panel B does not have
        Assert.Single(a.User.Favorites());                                                                 // and A did not lose anything
        _ = other;
    }

    [Fact]
    public async Task Pairing_needs_both_people_to_say_the_digits_match_and_the_receiving_device_to_be_on_its_add_a_device_screen()
    {
        var a = new Device(_dir, "a", "pidA", 1000); var b = new Device(_dir, "b", "pidB", 1000);
        b.Offers = false;
        Assert.IsType<LanOutcome.Refused>((await Sync(a, b)).Initiator); Assert.Empty(a.Trust.Peers); Assert.Empty(b.Trust.Peers);        // B is not showing its Add a device screen
        b.Offers = true; b.Confirms = false;
        Assert.IsType<LanOutcome.Refused>((await Sync(a, b)).Initiator); Assert.Empty(a.Trust.Peers); Assert.Empty(b.Trust.Peers);        // one person says the digits differ
        b.Confirms = true; a.Confirms = false;
        Assert.IsType<LanOutcome.Refused>((await Sync(a, b)).Responder); Assert.Empty(a.Trust.Peers); Assert.Empty(b.Trust.Peers);
    }

    [Fact]
    public async Task A_device_between_the_two_that_alters_a_frame_ends_the_conversation_and_nothing_is_applied()
    {
        var a = new Device(_dir, "a", "pidA", 1000); var b = new Device(_dir, "b", "pidB", 1000);
        a.User.ToggleFavorite(a.Key("movie:1"));
        int n = 0;
        var (i, r) = await Sync(a, b, (la, lb) => la.Tamper = f => ++n == 4 ? f.Select((x, k) => k == 0 ? (byte)(x ^ 1) : x).ToArray() : f);       // frames from A: hello, start, pair, then the data (4th), which is changed in transit
        Assert.IsType<LanOutcome.Failed>(r); Assert.Empty(b.User.Favorites());
        _ = i;
    }

    [Fact]
    public async Task Garbage_instead_of_a_hello_fails_cleanly_without_throwing()
    {
        var b = new Device(_dir, "b", "pidB", 1000); var (la, lb) = Pipe();
        var r = b.Protocol().RunResponderAsync(lb);
        await la.SendAsync(Encoding.UTF8.GetBytes("not json at all"));
        Assert.IsType<LanOutcome.Failed>(await r);
        var (lc, ld) = Pipe(); var r2 = b.Protocol().RunResponderAsync(ld);
        await lc.SendAsync(Encoding.UTF8.GetBytes("{\"t\":\"hello\",\"v\":1,\"pub\":\"AAAA\",\"name\":\"x\",\"nonce\":\"AAAAAAAAAAAAAAAAAAAAAA==\"}"));      // a key that is not a key
        Assert.IsType<LanOutcome.Failed>(await r2);
    }

    [Fact]
    public void Records_use_the_wire_form_the_other_apps_use()
    {
        var json = JsonSerializerRound(LanRecord.Make("fav", ["k", "movie", "9", "favorites"], 123, value: new() { ["at"] = 5L }));
        Assert.Equal("""{"k":"fav","key":["k","movie","9","favorites"],"ts":123,"v":{"at":5}}""", json);
        Assert.Equal("""{"k":"fav","key":["k"],"ts":1,"del":true}""", JsonSerializerRound(LanRecord.Make("fav", ["k"], 1, deleted: true)));
        var read = System.Text.Json.JsonSerializer.Deserialize<LanRecord>("""{"k":"prog","key":["a","movie","1"],"ts":9,"v":{"pos":12.5,"dur":100,"done":false,"series":null}}""")!;
        Assert.Equal(12.5, read.Num("pos")); Assert.Equal(false, read.Flag("done")); Assert.Null(read.Str("series")); Assert.False(read.Deleted);
    }

    private static string JsonSerializerRound(LanRecord r) => System.Text.Json.JsonSerializer.Serialize(r, new System.Text.Json.JsonSerializerOptions { DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull });

    [Fact]
    public void The_playlist_key_matches_the_Apple_apps()
    {
        Assert.Equal(LanSourceKey.Of("panel.example:8080"), LanSourceKey.Of("HTTP://Panel.Example:8080///"));
        Assert.Equal(Convert.ToHexString(SHA256.HashData("panel.example:8080"u8))[..16].ToLowerInvariant(), LanSourceKey.Of("http://panel.example:8080/"));
        Assert.NotEqual(LanSourceKey.Of("http://a.example"), LanSourceKey.Of("http://b.example"));
    }
}
