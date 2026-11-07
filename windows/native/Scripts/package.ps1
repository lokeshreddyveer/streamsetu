# Builds the installer: tests, build, signing, StreamSetu-Setup-<version>.exe, and the line to paste into the release notes.
#
#   powershell -ExecutionPolicy Bypass -File Scripts\package.ps1            (64-bit Intel/AMD)
#   powershell -ExecutionPolicy Bypass -File Scripts\package.ps1 -Arch arm64
#
# Signing uses a code-signing certificate that YOU provide; it is never stored in this folder or in git. Set ONE of:
#   STREAMSETU_SIGN_PFX + STREAMSETU_SIGN_PASSWORD   a .pfx file and its password
#   STREAMSETU_SIGN_THUMBPRINT                       a certificate already in the Windows certificate store (a hardware token works this way)
# Without either, an UNSIGNED installer is built, clearly marked, and the in-app updater will not run it for anyone.
#
# Needs: .NET 8 SDK, Visual Studio build tools, Inno Setup 6 (iscc.exe), and for signing the Windows SDK (signtool.exe).
param([ValidateSet("x64", "arm64")][string]$Arch = "x64", [switch]$SkipTests)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

# The version is the one in the program, so the installer, the file name and the update check agree.
$csproj = [xml](Get-Content "StreamSetu.App\StreamSetu.App.csproj")
$version = ($csproj.Project.PropertyGroup | ForEach-Object { $_.Version } | Where-Object { $_ } | Select-Object -First 1)
if (-not $version) { throw "No <Version> in StreamSetu.App.csproj." }

function Find-Tool($name, $extra) {
    $found = (Get-Command $name -ErrorAction SilentlyContinue).Source
    if ($found) { return $found }
    foreach ($pattern in $extra) { $hit = Get-ChildItem $pattern -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1; if ($hit) { return $hit.FullName } }
    return $null
}
$iscc = Find-Tool "iscc.exe" @("C:\Program Files (x86)\Inno Setup 6\ISCC.exe", "C:\Program Files\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe")
if (-not $iscc) { throw "Inno Setup 6 was not found. Install it from https://jrsoftware.org/isdl.php and run this again." }

$signing = $env:STREAMSETU_SIGN_PFX -or $env:STREAMSETU_SIGN_THUMBPRINT
$signtool = $null
if ($signing) {
    $signtool = Find-Tool "signtool.exe" @("C:\Program Files (x86)\Windows Kits\10\bin\*\x64\signtool.exe")
    if (-not $signtool) { throw "signtool.exe was not found. Install the Windows SDK (it comes with Visual Studio's .NET desktop workload)." }
}
function Sign-File($path) {
    if (-not $signing) { return }
    $signArgs = @("sign", "/fd", "SHA256", "/tr", "http://timestamp.digicert.com", "/td", "SHA256")
    if ($env:STREAMSETU_SIGN_PFX) { $signArgs += @("/f", $env:STREAMSETU_SIGN_PFX, "/p", $env:STREAMSETU_SIGN_PASSWORD) } else { $signArgs += @("/sha1", $env:STREAMSETU_SIGN_THUMBPRINT) }
    & $signtool @signArgs $path
    if ($LASTEXITCODE -ne 0) { throw "Signing $path failed." }
}

# 1. Test and build (build.ps1 refuses to build when a test fails).
$buildArgs = @{ Arch = $Arch }
if ($SkipTests) { $buildArgs.SkipTests = $true }
& "$PSScriptRoot\build.ps1" @buildArgs
$payload = Join-Path $root "dist\$Arch"
if (-not (Test-Path "$payload\StreamSetu.exe")) { throw "The build did not produce StreamSetu.exe." }

# 2. Sign the program, then wrap it in the installer, then sign the installer.
Sign-File "$payload\StreamSetu.exe"
$env:STREAMSETU_VERSION = $version
$env:STREAMSETU_PAYLOAD = $payload
& $iscc "installer\StreamSetu.iss"
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed." }
$installer = Join-Path $root "dist\StreamSetu-Setup-$version.exe"
if (-not (Test-Path $installer)) { throw "The installer was not produced." }
Sign-File $installer

# 3. Check what was made, and print what the release needs.
$sha = (Get-FileHash $installer -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host ""
Write-Host "Installer: $installer"
if ($signing) {
    $sig = Get-AuthenticodeSignature $installer
    if ($sig.Status -ne "Valid") { throw "The installer's signature is not valid: $($sig.Status) $($sig.StatusMessage)" }
    Write-Host "Signed by: $($sig.SignerCertificate.Subject)"
    Write-Host "Signer thumbprint (put this in SettingsPage.xaml.cs, PinnedSignerThumbprint, so the updater runs signed installers): $($sig.SignerCertificate.Thumbprint)"
} else {
    Write-Host "NOT SIGNED. People can still install it by hand (Windows will warn), and the in-app updater will download and check it but will not run it."
}
Write-Host ""
Write-Host "Add this line to the release notes (the updater reads the checksum from it) and attach the installer to the release:"
Write-Host ('`StreamSetu-Setup-{0}.exe`  {1}' -f $version, $sha)
