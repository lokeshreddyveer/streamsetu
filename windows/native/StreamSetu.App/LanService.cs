using System.Net;
using System.Net.Sockets;
using Microsoft.UI.Dispatching;
using StreamSetu.Core;
using Windows.Devices.Enumeration;
using Windows.Networking;
using Windows.Networking.ServiceDiscovery.Dnssd;
using Windows.Networking.Sockets;

namespace StreamSetu.App;

/// <summary>A device found on the network while sync is on.</summary>
internal sealed record FoundDevice(string Id, string Name, IPAddress Address, int Port);

/// <summary>Sync on this network (docs/WIFI-SYNC.md): announces this computer as _streamsetu-sync._tcp, looks for the others, answers connections, and syncs with paired devices. Nothing is sent to a device that is not paired,
/// and only addresses on this network are ever connected to.</summary>
internal sealed class LanService
{
    private const string ServiceType = "_streamsetu-sync._tcp";
    private const string IdentityKey = "lan.identity.device";
    private static readonly TimeSpan Limit = TimeSpan.FromMinutes(5);

    private readonly DispatcherQueue _ui;
    private readonly LanTrustStore _trust = new(AppServices.Store);
    private LanCrypto.Identity _identity = null!;
    private StreamSocketListener? _listener;
    private DeviceWatcher? _watcher;
    private DnssdServiceInstance? _instance;
    private readonly Dictionary<string, FoundDevice> _found = new();
    private DispatcherQueueTimer? _timer;
    private int _busy;

    public bool Enabled { get; private set; }
    /// <summary>True while the "Add a device" screen is open, so an unknown device that connects may be paired.</summary>
    public bool PairingOpen { get; set; }
    public string Status { get; private set; } = "Off";
    public DateTimeOffset? LastSync { get; private set; }
    public event Action? Changed;
    /// <summary>Shows the six digits to the person and returns their answer.</summary>
    public Func<string, string, Task<bool>>? Confirm { get; set; }

    public LanService(DispatcherQueue ui) { _ui = ui; }

    public IReadOnlyList<LanPeer> Paired => _trust.All();
    public IReadOnlyList<FoundDevice> Found { get { lock (_found) return _found.Values.OrderBy(f => f.Name).ToList(); } }
    public string DeviceName => Environment.MachineName;
    public void Forget(string id) { _trust.Remove(id); Raise(); }

    private void Raise() => _ui.TryEnqueue(() => Changed?.Invoke());
    private void SetStatus(string text) { Status = text; Raise(); }

    // The key that identifies this computer to the others. It stays in Credential Manager on this computer and is never synced anywhere.
    private LanCrypto.Identity Identity()
    {
        if (_identity is not null) return _identity;
        _identity = LanCrypto.Identity.Import(AppServices.Secrets.Get(IdentityKey)) ?? LanCrypto.Identity.Make();
        AppServices.Secrets.Set(IdentityKey, _identity.Export());
        return _identity;
    }

    public async Task StartAsync()
    {
        if (Enabled) return;
        try
        {
            var me = Identity();
            _listener = new StreamSocketListener();
            _listener.ConnectionReceived += OnConnection;
            await _listener.BindServiceNameAsync("");
            var port = ushort.Parse(_listener.Information.LocalPort);

            _instance = new DnssdServiceInstance($"{me.DeviceId}.{ServiceType}.local", new HostName(Environment.MachineName), port);
            _instance.TextAttributes["id"] = me.DeviceId;
            _instance.TextAttributes["name"] = DeviceName;
            await _instance.RegisterStreamSocketListenerAsync(_listener);

            var selector = "System.Devices.AepService.ProtocolId:={4526e8c1-8aac-4153-9b16-55e86ada0e54} AND System.Devices.Dnssd.Domain:=\"local\" AND System.Devices.Dnssd.ServiceName:=\"" + ServiceType + "\"";
            _watcher = DeviceInformation.CreateWatcher(selector, new[] { "System.Devices.Dnssd.HostName", "System.Devices.Dnssd.ServiceName", "System.Devices.Dnssd.PortNumber", "System.Devices.IpAddress", "System.Devices.Dnssd.TextAttributes" }, DeviceInformationKind.AssociationEndpointService);
            _watcher.Added += (_, info) => OnFound(info);
            _watcher.Removed += (_, update) => { lock (_found) _found.Remove(update.Id); Raise(); };
            _watcher.Start();

            Enabled = true;
            _timer = _ui.CreateTimer(); _timer.Interval = TimeSpan.FromMinutes(5); _timer.Tick += (_, _) => _ = SyncAllAsync();
            _timer.Start();
            SetStatus("On. Looking for your other devices.");
        }
        catch (Exception e)
        {
            await StopAsync();
            SetStatus("Could not start: " + e.Message);
        }
    }

    public Task StopAsync()
    {
        Enabled = false; _timer?.Stop(); _timer = null;
        try { if (_watcher is { Status: DeviceWatcherStatus.Started or DeviceWatcherStatus.EnumerationCompleted }) _watcher.Stop(); } catch (Exception) { }
        _watcher = null;
        try { _listener?.Dispose(); } catch (Exception) { }
        _listener = null; _instance = null;
        lock (_found) _found.Clear();
        SetStatus("Off");
        return Task.CompletedTask;
    }

    private void OnFound(DeviceInformation info)
    {
        try
        {
            var text = info.Properties.TryGetValue("System.Devices.Dnssd.TextAttributes", out var t) ? t as string[] : null;
            string? id = null, name = null;
            foreach (var line in text ?? Array.Empty<string>()) { if (line.StartsWith("id=")) id = line[3..]; else if (line.StartsWith("name=")) name = line[5..]; }
            if (id is null || id == Identity().DeviceId) return;
            var port = info.Properties.TryGetValue("System.Devices.Dnssd.PortNumber", out var p) && p is not null ? Convert.ToInt32(p) : 0;
            // Only an address on this network is ever connected to.
            var address = (info.Properties.TryGetValue("System.Devices.IpAddress", out var a) ? a as string[] : null)?.Select(s => IPAddress.TryParse(s, out var ip) ? ip : null).FirstOrDefault(ip => ip is not null && AddressPolicy.IsLocalNetwork(ip));
            if (address is null || port <= 0 || port > 65535) return;
            lock (_found) _found[info.Id] = new FoundDevice(id, string.IsNullOrWhiteSpace(name) ? "Device" : name!, address, port);
            Raise();
        }
        catch (Exception) { /* a malformed announcement is ignored */ }
    }

    private LanProtocol Protocol() => new(Identity(), DeviceName, _trust, new LanSyncData(AppServices.User, AppServices.Playlists().ToList()), () => PairingOpen, (digits, peer) => AskAsync(digits, peer));

    private Task<bool> AskAsync(string digits, string peer)
    {
        var tcs = new TaskCompletionSource<bool>();
        _ui.TryEnqueue(async () =>
        {
            try { tcs.SetResult(Confirm is null ? false : await Confirm(digits, peer)); } catch (Exception) { tcs.TrySetResult(false); }
        });
        return tcs.Task;
    }

    // ---------- Another device connects to this one ----------

    private async void OnConnection(StreamSocketListener sender, StreamSocketListenerConnectionReceivedEventArgs args)
    {
        try
        {
            using var socket = args.Socket;
            using var cts = new CancellationTokenSource(Limit);
            var stream = new DuplexStream(socket.InputStream.AsStreamForRead(), socket.OutputStream.AsStreamForWrite());
            var outcome = await Protocol().RunResponderAsync(new StreamLanLink(stream), cts.Token);
            Finish(outcome);
        }
        catch (Exception) { /* a connection that breaks is just over */ }
    }

    // ---------- This device connects to another ----------

    public async Task<LanOutcome> SyncWithAsync(FoundDevice device)
    {
        if (Interlocked.Exchange(ref _busy, 1) == 1) return new LanOutcome.Failed("Already syncing.");
        try
        {
            if (!AddressPolicy.IsLocalNetwork(device.Address)) return new LanOutcome.Failed("That device is not on this network.");
            using var client = new TcpClient();
            using var cts = new CancellationTokenSource(Limit);
            using var connectTimeout = CancellationTokenSource.CreateLinkedTokenSource(cts.Token); connectTimeout.CancelAfter(TimeSpan.FromSeconds(15));
            await client.ConnectAsync(device.Address, device.Port, connectTimeout.Token);
            var outcome = await Protocol().RunInitiatorAsync(new StreamLanLink(client.GetStream()), cts.Token);
            Finish(outcome);
            return outcome;
        }
        catch (Exception e) when (e is SocketException or IOException or OperationCanceledException) { var o = new LanOutcome.Failed("Could not reach " + device.Name); Finish(o); return o; }
        finally { Interlocked.Exchange(ref _busy, 0); }
    }

    /// <summary>Syncs with every paired device that is on the network now.</summary>
    public async Task SyncAllAsync()
    {
        var paired = Paired.Select(p => p.Id).ToHashSet();
        foreach (var d in Found.Where(f => paired.Contains(f.Id))) await SyncWithAsync(d);
    }

    private void Finish(LanOutcome outcome)
    {
        switch (outcome)
        {
            case LanOutcome.Synced s: LastSync = DateTimeOffset.Now; SetStatus($"Synced with {s.Peer.Name}" + (s.Received > 0 ? $": {s.Received} changes" : ": already up to date")); break;
            case LanOutcome.Refused r: SetStatus("Not synced: " + (r.Why == "not-paired" ? "the other device is not showing its Add a device screen" : r.Why)); break;
            case LanOutcome.Failed f: SetStatus("Sync did not finish: " + f.Why); break;
        }
    }
}
