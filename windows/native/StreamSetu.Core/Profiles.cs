using System.Security.Cryptography;
using System.Text;

namespace StreamSetu.Core;

/// <summary>A PIN kept as a salted hash, never as the number itself.</summary>
public sealed record PinHash(string Salt, string Hash)
{
    private const int Iterations = 100_000;

    public static bool IsValid(string? pin) => pin is { Length: >= 4 and <= 8 } && pin.All(char.IsAsciiDigit);

    public static PinHash Make(string pin)
    {
        if (!IsValid(pin)) throw new ArgumentException("A PIN is 4 to 8 digits.");
        var salt = RandomNumberGenerator.GetBytes(16);
        return new PinHash(Convert.ToBase64String(salt), Convert.ToBase64String(Derive(pin, salt)));
    }

    public bool Matches(string pin)
    {
        if (!IsValid(pin)) return false;
        try { return CryptographicOperations.FixedTimeEquals(Derive(pin, Convert.FromBase64String(Salt)), Convert.FromBase64String(Hash)); }
        catch (FormatException) { return false; }
    }

    private static byte[] Derive(string pin, byte[] salt) => Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(pin), salt, Iterations, HashAlgorithmName.SHA256, 32);
}

public sealed record Profile(string Id, string Name, bool Kids, PinHash? Pin = null);

public enum PinResult { Ok, Wrong, Locked, NoPin }

/// <summary>Up to four people on one computer, each with their own favourites, history, collections and folders. Connections are shared. A Kids profile keeps locked folders hidden.
/// Wrong PINs are counted on disk, so closing the app does not reset the count.</summary>
public sealed class ProfileManager
{
    public const int MaxProfiles = 4, MaxWrong = 5;
    public static readonly TimeSpan LockFor = TimeSpan.FromMinutes(1);

    private sealed record Lock(int Wrong, DateTimeOffset? Until);

    private readonly LocalStore _root;
    private readonly Func<DateTimeOffset> _now;
    public ProfileManager(LocalStore root, Func<DateTimeOffset>? now = null)
    {
        _root = root; _now = now ?? (() => DateTimeOffset.UtcNow);
        if (All().Count == 0) _root.Save("Profiles", new List<Profile> { new("main", "Me", false) });
    }

    public List<Profile> All() => _root.Load("Profiles", new List<Profile>());

    public Profile? Find(string id) => All().FirstOrDefault(p => p.Id == id);

    /// <summary>The folder holding one profile's favourites, history and the rest.</summary>
    public LocalStore StoreOf(string id)
    {
        if (Find(id) is null) throw new ArgumentException("No such profile.");
        return new LocalStore(Path.Combine(_root.Folder, "profiles", id));
    }

    public Profile Add(string name, bool kids)
    {
        var all = All();
        if (all.Count >= MaxProfiles) throw new InvalidOperationException($"There can be up to {MaxProfiles} profiles.");
        name = name.Trim();
        if (name.Length == 0) throw new ArgumentException("A profile needs a name.");
        if (all.Any(p => string.Equals(p.Name, name, StringComparison.CurrentCultureIgnoreCase))) throw new InvalidOperationException("There is already a profile with that name.");
        var profile = new Profile(Guid.NewGuid().ToString("N")[..10], name, kids);
        all.Add(profile); _root.Save("Profiles", all);
        return profile;
    }

    public void Remove(string id)
    {
        var all = All();
        if (all.Count <= 1) throw new InvalidOperationException("The last profile cannot be removed.");
        if (all.RemoveAll(p => p.Id == id) == 0) return;
        _root.Save("Profiles", all);
        var folder = Path.Combine(_root.Folder, "profiles", id);
        if (Directory.Exists(folder)) Directory.Delete(folder, true);
    }

    private void Replace(Profile updated) { var all = All(); var i = all.FindIndex(p => p.Id == updated.Id); if (i >= 0) { all[i] = updated; _root.Save("Profiles", all); } }

    public void SetPin(string id, string? pin)
    {
        var p = Find(id) ?? throw new ArgumentException("No such profile.");
        Replace(p with { Pin = pin is null ? null : PinHash.Make(pin) });
        SaveLock(id, new Lock(0, null));
    }

    public void SetKids(string id, bool kids) { if (Find(id) is { } p) Replace(p with { Kids = kids }); }

    private Dictionary<string, Lock> Locks() => _root.Load("PinLocks", new Dictionary<string, Lock>());
    private void SaveLock(string id, Lock l) { var all = Locks(); all[id] = l; _root.Save("PinLocks", all); }

    /// <summary>Checks a PIN. After five wrong ones in a row the profile is locked for a minute; the count survives a restart.</summary>
    public PinResult CheckPin(string id, string pin)
    {
        var p = Find(id);
        if (p?.Pin is null) return PinResult.NoPin;
        var l = Locks().GetValueOrDefault(id) ?? new Lock(0, null);
        if (l.Until is { } until && _now() < until) return PinResult.Locked;
        if (p.Pin.Matches(pin)) { SaveLock(id, new Lock(0, null)); return PinResult.Ok; }
        var wrong = l.Wrong + 1;
        SaveLock(id, wrong >= MaxWrong ? new Lock(0, _now() + LockFor) : new Lock(wrong, null));
        return wrong >= MaxWrong ? PinResult.Locked : PinResult.Wrong;
    }
}
