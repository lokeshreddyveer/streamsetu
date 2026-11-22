using System.Text;
using StreamSetu.Core;
using Xunit;

namespace StreamSetu.Core.Tests;

public class PayloadTests
{
    private static string Temp() { var d = Path.Combine(Path.GetTempPath(), "ss-pay-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(d); return d; }

    private static (string Out, string Dir, string Root) Make(string version = "0.2.0")
    {
        var root = Temp(); var app = Path.Combine(root, "app"); Directory.CreateDirectory(Path.Combine(app, "Assets", "TuneIn"));
        File.WriteAllText(Path.Combine(app, "StreamSetu.exe"), "the program");
        File.WriteAllBytes(Path.Combine(app, "libmpv-2.dll"), Enumerable.Range(0, 5000).Select(i => (byte)(i * 7)).ToArray());
        File.WriteAllText(Path.Combine(app, "Assets", "TuneIn", "screen.png"), "picture");
        var launcher = Path.Combine(root, "launcher.exe"); File.WriteAllBytes(launcher, Encoding.ASCII.GetBytes("MZ-launcher-program"));
        var outFile = Path.Combine(root, "StreamSetu-Windows.exe");
        Payload.Build(launcher, app, version, "StreamSetu.exe", outFile);
        return (outFile, app, root);
    }

    [Fact]
    public void BuiltFileStartsWithTheLauncherAndCarriesTheList()
    {
        var (exe, app, _) = Make();
        Assert.Equal("MZ-launcher-program", Encoding.ASCII.GetString(File.ReadAllBytes(exe), 0, 19));
        var l = Payload.Locate(exe)!;
        Assert.Equal("0.2.0", l.Manifest.Version); Assert.Equal(19, l.ZipOffset);
        Assert.Equal(new[] { "Assets/TuneIn/screen.png", "StreamSetu.exe", "libmpv-2.dll" }, l.Manifest.Files.Select(f => f.Path));
        Assert.Equal(64, l.Manifest.Files[0].Sha256.Length);
        Assert.Empty(Payload.Problems(app, l.Manifest));
    }

    [Fact]
    public void FirstRunUnpacksEverythingAndALaterRunFindsNothingToDo()
    {
        var (exe, _, root) = Make(); var l = Payload.Locate(exe)!;
        var folder = Payload.AppFolder(Path.Combine(root, "data"), l.Manifest.Version);
        Assert.Equal(3, Payload.Problems(folder, l.Manifest).Count);
        Payload.Restore(exe, l, folder, Payload.Problems(folder, l.Manifest));
        Assert.Empty(Payload.Problems(folder, l.Manifest));
        Assert.Equal("the program", File.ReadAllText(Path.Combine(folder, "StreamSetu.exe")));
        Assert.True(File.Exists(Path.Combine(folder, "Assets", "TuneIn", "screen.png")));
        Assert.Empty(Directory.EnumerateFiles(folder, "*.part", SearchOption.AllDirectories));
        Assert.EndsWith("app-0.2.0", folder);
    }

    [Fact]
    public void MissingChangedAndTruncatedFilesAreFoundAndPutBack()
    {
        var (exe, _, root) = Make(); var l = Payload.Locate(exe)!;
        var folder = Path.Combine(root, "data", "app-0.2.0");
        Payload.Restore(exe, l, folder, Payload.Problems(folder, l.Manifest));
        File.Delete(Path.Combine(folder, "Assets", "TuneIn", "screen.png"));
        File.AppendAllText(Path.Combine(folder, "libmpv-2.dll"), "x");                          // changed
        File.WriteAllText(Path.Combine(folder, "StreamSetu.exe"), "the progrXm");                // same size, different content
        var bad = Payload.Problems(folder, l.Manifest);
        Assert.Equal(new[] { "Assets/TuneIn/screen.png", "StreamSetu.exe", "libmpv-2.dll" }, bad);
        Payload.Restore(exe, l, folder, bad);
        Assert.Empty(Payload.Problems(folder, l.Manifest));
        Assert.Equal("the program", File.ReadAllText(Path.Combine(folder, "StreamSetu.exe")));
    }

    [Fact]
    public void ADamagedPackageIsRefusedNotUnpacked()
    {
        var (exe, _, root) = Make();
        var l0 = Payload.Locate(exe)!; var bytes = File.ReadAllBytes(exe); for (var i = l0.ZipOffset + 30; i < l0.ZipOffset + l0.ZipLength - 100; i += 3) bytes[i] ^= 0xFF;         // inside the zip
        var broken = Path.Combine(root, "broken.exe"); File.WriteAllBytes(broken, bytes);
        var l = Payload.Locate(broken)!;
        var folder = Path.Combine(root, "data", "app-0.2.0");
        Assert.ThrowsAny<Exception>(() => Payload.Restore(broken, l, folder, Payload.Problems(folder, l.Manifest)));
        Assert.NotEmpty(Payload.Problems(folder, l.Manifest));                                      // nothing damaged was accepted as good
    }

    [Fact]
    public void AFileWithoutAPackageIsNotOne()
    {
        var root = Temp(); var plain = Path.Combine(root, "plain.exe"); File.WriteAllText(plain, "just a program, nothing appended to it at all");
        Assert.Null(Payload.Locate(plain));
        var tiny = Path.Combine(root, "tiny.exe"); File.WriteAllText(tiny, "x"); Assert.Null(Payload.Locate(tiny));
    }

    [Fact]
    public void NothingIsWrittenOutsideTheFolder()
    {
        var (exe, _, root) = Make(); var l = Payload.Locate(exe)!;
        var evil = new Payload.Located(l.ZipOffset, l.ZipLength, l.Manifest with { Files = new() { new PayloadFile("../escape.txt", new string('0', 64), 1) } });
        Assert.Throws<InvalidOperationException>(() => Payload.Problems(Path.Combine(root, "data", "app-0.2.0"), evil.Manifest).Count);
    }

    [Fact]
    public void OnlyOlderAppFoldersGoAndUserDataStays()
    {
        var root = Temp();
        foreach (var d in new[] { "app-0.1.0", "app-0.2.0", "app-0.3.0", "logos", "app-notaversion" }) Directory.CreateDirectory(Path.Combine(root, d));
        File.WriteAllText(Path.Combine(root, "Playlists.json"), "[]"); File.WriteAllText(Path.Combine(root, "app-0.1.0", "x.dll"), "x");
        var removed = Payload.RemoveOlder(root, "0.2.0");
        Assert.Equal(new[] { "app-0.1.0", "app-0.3.0" }, removed.OrderBy(x => x));
        Assert.True(Directory.Exists(Path.Combine(root, "app-0.2.0"))); Assert.True(Directory.Exists(Path.Combine(root, "logos"))); Assert.True(Directory.Exists(Path.Combine(root, "app-notaversion")));
        Assert.True(File.Exists(Path.Combine(root, "Playlists.json")));
    }
}

public class UpdateAssetTests
{
    private static string Release(params string[] names) =>
        "{\"assets\":[" + string.Join(",", names.Select(n => $"{{\"name\":\"{n}\",\"browser_download_url\":\"{Updates.ReleasesPrefix}v/{n}\"}}")) + "],\"body\":\"" + string.Join(" ", names.Select(n => $"`{n}` {new string('a', 64)}")) + "\"}";

    [Fact]
    public void TheOneFileDownloadIsOfferedForTheRightKindOfComputer()
    {
        var json = Release("StreamSetu-Windows-0.3.0.exe", "StreamSetu-Windows-0.3.0-arm64.exe");
        Assert.Equal("StreamSetu-Windows-0.3.0.exe", Updates.Parse(json, new Version(0, 2, 0))!.AssetName);
        Assert.Equal("StreamSetu-Windows-0.3.0-arm64.exe", Updates.Parse(json, new Version(0, 2, 0), arm64: true)!.AssetName);
        Assert.Null(Updates.Parse(json, new Version(0, 3, 0)));
        Assert.Equal("StreamSetu-Setup-0.3.0.exe", Updates.Parse(Release("StreamSetu-Setup-0.3.0.exe"), new Version(0, 2, 0))!.AssetName);
    }
}
