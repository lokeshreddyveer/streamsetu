using System.IO.Compression;
using System.Text.Json;

namespace StreamSetu.Core;

/// <summary>Saves the app's data folder to one file and restores it. A backup file is outside data: restoring checks every entry (plain .json files directly inside the known folders, no
/// path tricks, size limits, readable JSON) before anything is replaced, and the data being replaced is kept beside it. Passwords are not in the backup: they are in Credential Manager.</summary>
public static class Backup
{
    public const long MaxEntryBytes = 64L * 1024 * 1024, MaxTotalBytes = 256L * 1024 * 1024;
    public const int MaxEntries = 200;

    public static void Export(string dataFolder, string zipPath)
    {
        if (File.Exists(zipPath)) File.Delete(zipPath);
        using var zip = ZipFile.Open(zipPath, ZipArchiveMode.Create);
        foreach (var file in Directory.EnumerateFiles(dataFolder, "*.json", SearchOption.AllDirectories))
            zip.CreateEntryFromFile(file, Path.GetRelativePath(dataFolder, file).Replace('\\', '/'));
    }

    /// <summary>Why an entry name cannot be trusted, or null when it can.</summary>
    public static string? BadName(string name)
    {
        if (name.Length == 0 || name.EndsWith('/')) return "a folder entry";
        if (name.StartsWith('/') || name.StartsWith('\\') || name.Contains(':') || name.Contains('\\')) return "an absolute or drive path";
        var parts = name.Split('/');
        if (parts.Any(p => p is "" or "." or "..")) return "a path that leaves the data folder";
        if (!name.EndsWith(".json", StringComparison.OrdinalIgnoreCase)) return "not a .json file";
        if (parts.Length > 3) return "nested too deep";
        return null;
    }

    /// <summary>Restores into <paramref name="dataFolder"/>. Returns the folder the previous data was moved to.</summary>
    public static string Restore(string zipPath, string dataFolder)
    {
        var staging = dataFolder.TrimEnd(Path.DirectorySeparatorChar) + ".restoring-" + Guid.NewGuid().ToString("N")[..8];
        Directory.CreateDirectory(staging);
        try
        {
            using (var zip = ZipFile.OpenRead(zipPath))
            {
                if (zip.Entries.Count > MaxEntries) throw new InvalidOperationException("This backup has too many files to be one of ours.");
                long total = 0;
                foreach (var e in zip.Entries)
                {
                    if (BadName(e.FullName) is { } why) throw new InvalidOperationException($"This backup is not safe to restore ({e.FullName}: {why}).");
                    total += e.Length;
                    if (e.Length > MaxEntryBytes || total > MaxTotalBytes) throw new InvalidOperationException("This backup is larger than any of ours.");
                    var target = Path.GetFullPath(Path.Combine(staging, e.FullName));
                    if (!target.StartsWith(Path.GetFullPath(staging) + Path.DirectorySeparatorChar, StringComparison.Ordinal)) throw new InvalidOperationException("This backup is not safe to restore.");
                    Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                    e.ExtractToFile(target, overwrite: false);
                    try { using var s = File.OpenRead(target); JsonDocument.Parse(s).Dispose(); }
                    catch (JsonException) { throw new InvalidOperationException($"{e.FullName} in this backup is damaged."); }
                }
            }
            var before = dataFolder.TrimEnd(Path.DirectorySeparatorChar) + ".before-restore-" + DateTime.UtcNow.ToString("yyyyMMddHHmmss");
            if (Directory.Exists(dataFolder)) Directory.Move(dataFolder, before);
            Directory.Move(staging, dataFolder);
            return before;
        }
        catch { if (Directory.Exists(staging)) Directory.Delete(staging, true); throw; }
    }
}
