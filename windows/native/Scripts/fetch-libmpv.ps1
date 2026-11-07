# Downloads libmpv (the player engine) once and puts libmpv-2.dll where the project expects it.
#   powershell -ExecutionPolicy Bypass -File Scripts\fetch-libmpv.ps1            (64-bit Intel/AMD)
#   powershell -ExecutionPolicy Bypass -File Scripts\fetch-libmpv.ps1 -Arch aarch64   (Windows on ARM)
param([ValidateSet("x86_64", "aarch64")][string]$Arch = "x86_64")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$platform = if ($Arch -eq "x86_64") { "x64" } else { "ARM64" }
$target = Join-Path $root "StreamSetu.App\libmpv\$platform"
New-Item -ItemType Directory -Force $target | Out-Null

Write-Host "Finding the latest libmpv build for $Arch..."
$release = Invoke-RestMethod "https://api.github.com/repos/shinchiro/mpv-winbuild-cmake/releases/latest" -Headers @{ "User-Agent" = "StreamSetu" }
$asset = $release.assets | Where-Object { $_.name -match "^mpv-dev-$Arch-\d{8}-git-.*\.7z$" } | Select-Object -First 1
if (-not $asset) { throw "No libmpv download was found for $Arch on the release page." }

$work = Join-Path ([IO.Path]::GetTempPath()) ("libmpv-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory $work | Out-Null
try {
    $archive = Join-Path $work $asset.name
    Write-Host "Downloading $($asset.name) ($([math]::Round($asset.size / 1MB)) MB)..."
    Invoke-WebRequest $asset.browser_download_url -OutFile $archive
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
