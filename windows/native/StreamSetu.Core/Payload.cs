using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace StreamSetu.Core;

public sealed record PayloadFile(string Path, string Sha256, long Size);
public sealed record PayloadManifest(string Version, string Exe, List<PayloadFile> Files);

/// <summary>The one-file download: the launcher program with the whole app (a zip) and a list of every file's SHA-256 appended to it.
/// Layout: [launcher][zip][manifest json][trailer: "SSPAYLD1", zip length, json length]. Nothing is packed or obfuscated.
/// The launcher unpacks it once into a folder of its own, checks every file against the list on every start, and puts back what is missing or changed.</summary>
public static class Payload
{
    public const string Magic = "SSPAYLD1";
    private const int TrailerLength = 8 + 8 + 8;
    private static readonly Regex AppFolderName = new(@"^app-\d+(\.\d+){1,3}$", RegexOptions.CultureInvariant);
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = false };

    public sealed record Located(long ZipOffset, long ZipLength, PayloadManifest Manifest);

    // ---------- Build side ----------

    public static PayloadManifest BuildManifest(string version, string exe, string folder)
    {
        var root = Path.GetFullPath(folder);
        var files = Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories).OrderBy(f => f, StringComparer.Ordinal)
            .Select(f => { using var s = File.OpenRead(f); return new PayloadFile(Path.GetRelativePath(root, f).Replace('\\', '/'), Convert.ToHexString(SHA256.HashData(s)).ToLowerInvariant(), new FileInfo(f).Length); }).ToList();
        if (!files.Any(f => f.Path == exe)) throw new FileNotFoundException("The program is not in the folder: " + exe);
        return new PayloadManifest(version, exe, files);
    }

    /// <summary>Writes <paramref name="outFile"/>: the launcher, then the folder as a zip, then the manifest and the trailer.</summary>
    public static void Build(string launcherExe, string folder, string version, string exe, string outFile)
    {
        var manifest = BuildManifest(version, exe, folder);
        var zip = Path.GetTempFileName();
        try
        {
            File.Delete(zip);
            ZipFile.CreateFromDirectory(folder, zip, CompressionLevel.Optimal, includeBaseDirectory: false);
            var json = JsonSerializer.SerializeToUtf8Bytes(manifest, Json);
            File.Copy(launcherExe, outFile, overwrite: true);
            using var o = new FileStream(outFile, FileMode.Append, FileAccess.Write);
            using (var z = File.OpenRead(zip)) z.CopyTo(o);
            o.Write(json);
            var zipLength = new FileInfo(zip).Length;
            Span<byte> trailer = stackalloc byte[TrailerLength];
            Encoding.ASCII.GetBytes(Magic, trailer);
            BitConverter.TryWriteBytes(trailer[8..], zipLength); BitConverter.TryWriteBytes(trailer[16..], (long)json.Length);
            o.Write(trailer);
        }
        finally { if (File.Exists(zip)) File.Delete(zip); }
    }

    // ---------- Run side ----------

    public static Located? Locate(string exePath)
    {
        using var f = new FileStream(exePath, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (f.Length < TrailerLength) return null;
        var t = new byte[TrailerLength];
        f.Seek(-TrailerLength, SeekOrigin.End); f.ReadExactly(t);
        if (Encoding.ASCII.GetString(t, 0, 8) != Magic) return null;
        var zipLength = BitConverter.ToInt64(t, 8); var jsonLength = BitConverter.ToInt64(t, 16);
        if (zipLength <= 0 || jsonLength <= 0 || zipLength + jsonLength + TrailerLength > f.Length) return null;
        var json = new byte[jsonLength];
        f.Seek(f.Length - TrailerLength - jsonLength, SeekOrigin.Begin); f.ReadExactly(json);
        var manifest = JsonSerializer.Deserialize<PayloadManifest>(json, Json);
        if (manifest is null || manifest.Files.Count == 0 || !Regex.IsMatch(manifest.Version, @"^\d+(\.\d+){1,3}$")) return null;
        return new Located(f.Length - TrailerLength - jsonLength - zipLength, zipLength, manifest);
    }

    public static string AppFolder(string dataRoot, string version) => Path.Combine(dataRoot, "app-" + version);

    private static string Resolve(string folder, string relative)
    {
        var root = Path.GetFullPath(folder);
        var full = Path.GetFullPath(Path.Combine(root, relative));
        if (!full.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.Ordinal)) throw new InvalidOperationException("A file in the package points outside its folder: " + relative);
        return full;
    }

    /// <summary>The files that are missing, a different size, or not the file in the list.</summary>
    public static List<string> Problems(string folder, PayloadManifest m)
    {
        var bad = new System.Collections.Concurrent.ConcurrentBag<string>();
        Parallel.ForEach(m.Files, f =>
        {
            try
            {
                var path = Resolve(folder, f.Path);
                var info = new FileInfo(path);
                if (!info.Exists || info.Length != f.Size) { bad.Add(f.Path); return; }
                using var s = File.OpenRead(path);
                if (!string.Equals(Convert.ToHexString(SHA256.HashData(s)), f.Sha256, StringComparison.OrdinalIgnoreCase)) bad.Add(f.Path);
            }
            catch (IOException) { bad.Add(f.Path); }
            catch (UnauthorizedAccessException) { bad.Add(f.Path); }
        });
        return bad.OrderBy(p => p, StringComparer.Ordinal).ToList();
    }

    /// <summary>Puts back the listed files from the package inside the exe. Each is written beside its place, checked, then moved in. Progress is 0..1.</summary>
    public static void Restore(string exePath, Located l, string folder, IReadOnlyCollection<string> paths, Action<double>? progress = null)
    {
        Directory.CreateDirectory(folder);
        using var file = new FileStream(exePath, FileMode.Open, FileAccess.Read, FileShare.Read);
        using var zip = new ZipArchive(new SubStream(file, l.ZipOffset, l.ZipLength), ZipArchiveMode.Read);
        var byPath = l.Manifest.Files.ToDictionary(f => f.Path);
        var done = 0; long total = paths.Sum(p => byPath[p].Size), written = 0;
        foreach (var p in paths)
        {
            var want = byPath[p];
            var entry = zip.GetEntry(p) ?? throw new InvalidDataException("The package does not contain " + p);
            var dest = Resolve(folder, p);
            Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
            var part = dest + ".part";
            using (var src = entry.Open())
            using (var dst = new FileStream(part, FileMode.Create, FileAccess.Write, FileShare.None)) src.CopyTo(dst);
            using (var check = File.OpenRead(part))
                if (!string.Equals(Convert.ToHexString(SHA256.HashData(check)), want.Sha256, StringComparison.OrdinalIgnoreCase)) { File.Delete(part); throw new InvalidDataException("The package is damaged (" + p + "). Download it again."); }
            File.Move(part, dest, overwrite: true);
            written += want.Size; done++;
            progress?.Invoke(total == 0 ? 1 : (double)written / total);
        }
    }

    /// <summary>Removes the folders of other versions (only those named app-N.N.N, and only inside <paramref name="dataRoot"/>). A folder that is in use is left alone.</summary>
    public static List<string> RemoveOlder(string dataRoot, string currentVersion)
    {
        var removed = new List<string>();
        if (!Directory.Exists(dataRoot)) return removed;
        foreach (var dir in Directory.EnumerateDirectories(dataRoot))
        {
            var name = Path.GetFileName(dir);
            if (!AppFolderName.IsMatch(name) || name == "app-" + currentVersion) continue;
            try { Directory.Delete(dir, recursive: true); removed.Add(name); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { /* still running or locked: tried again next time */ }
        }
        return removed;
    }

    /// <summary>A read-only window onto part of a file, so a zip inside the exe can be read in place.</summary>
    private sealed class SubStream(Stream inner, long offset, long length) : Stream
    {
        private long _pos;
        public override bool CanRead => true; public override bool CanSeek => true; public override bool CanWrite => false;
        public override long Length => length;
        public override long Position { get => _pos; set => _pos = value; }
        public override int Read(byte[] buffer, int off, int count)
        {
            var n = (int)Math.Max(0, Math.Min(count, length - _pos));
            if (n == 0) return 0;
            inner.Seek(offset + _pos, SeekOrigin.Begin);
            var got = inner.Read(buffer, off, n); _pos += got; return got;
        }
        public override long Seek(long o, SeekOrigin origin) => _pos = origin switch { SeekOrigin.Begin => o, SeekOrigin.Current => _pos + o, _ => length + o };
        public override void Flush() { }
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int off, int count) => throw new NotSupportedException();
    }
}
