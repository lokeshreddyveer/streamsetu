# Downloads libmpv (the player engine) once and puts libmpv-2.dll where the project expects it.
#   powershell -ExecutionPolicy Bypass -File Scripts\fetch-libmpv.ps1            (64-bit Intel/AMD)
#   powershell -ExecutionPolicy Bypass -File Scripts\fetch-libmpv.ps1 -Arch aarch64   (Windows on ARM)
param([ValidateSet("x86_64", "aarch64")][string]$Arch = "x86_64")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$platform = if ($Arch -eq "x86_64") { "x64" } else { "ARM64" }
$target = Join-Path $root "StreamSetu.App\libmpv\$platform"
New-Item -ItemType Directory -Force $target | Out-Null

# Pinned: this exact build, and the file must match its SHA-256 or nothing is used. To move to a newer build, change the tag, the file name and both checksums together.
$tag = "20261111"
$pins = @{
    "x86_64"  = @{ Name = "mpv-dev-x86_64-20261111-git-bcde6b93cc.7z";  Sha256 = "273c079b11ea5575822f972756f4c9a71149a5c10130353abeb8586738938452" }
    "aarch64" = @{ Name = "mpv-dev-aarch64-20261111-git-bcde6b93cc.7z"; Sha256 = "a42c1cebf7366a957c7c321a20df414b80d4a55bbc65ded032d78b749c8d6445" }
}
$pin = $pins[$Arch]
$asset = [pscustomobject]@{ name = $pin.Name; browser_download_url = "https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/$tag/$($pin.Name)"; size = 0 }

$work = Join-Path ([IO.Path]::GetTempPath()) ("libmpv-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory $work | Out-Null
try {
    $archive = Join-Path $work $asset.name
    Write-Host "Downloading $($asset.name)..."
    Invoke-WebRequest $asset.browser_download_url -OutFile $archive
    $actual = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $pin.Sha256) { throw "The libmpv download does not match its pinned checksum ($actual). Nothing was used." }
    # Windows 11 can open .7z with its built-in tar; otherwise 7-Zip is used if it is installed.
    $extracted = Join-Path $work "x"
    New-Item -ItemType Directory $extracted | Out-Null
    & tar -xf $archive -C $extracted 2>$null
    if (-not (Test-Path (Join-Path $extracted "libmpv-2.dll"))) {
        $sevenZip = (Get-Command 7z -ErrorAction SilentlyContinue).Source
        if (-not $sevenZip -and (Test-Path "C:\Program Files\7-Zip\7z.exe")) { $sevenZip = "C:\Program Files\7-Zip\7z.exe" }
        if (-not $sevenZip) { throw "This computer cannot open .7z files. Install 7-Zip (https://www.7-zip.org) and run this again." }
        & $sevenZip x $archive "-o$extracted" -y | Out-Null
    }
    $dll = Get-ChildItem $extracted -Recurse -Filter "libmpv-2.dll" | Select-Object -First 1
    if (-not $dll) { throw "libmpv-2.dll was not in the download." }
    Copy-Item $dll.FullName (Join-Path $target "libmpv-2.dll") -Force
    Write-Host "Done: $target\libmpv-2.dll"
}
finally { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
