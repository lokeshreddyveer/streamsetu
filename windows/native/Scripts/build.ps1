# Builds StreamSetu for Windows into windows\native\dist\<arch>\ (a folder you can run StreamSetu.exe from, or zip).
#   powershell -ExecutionPolicy Bypass -File Scripts\build.ps1            (64-bit Intel/AMD)
#   powershell -ExecutionPolicy Bypass -File Scripts\build.ps1 -Arch arm64
param([ValidateSet("x64", "arm64")][string]$Arch = "x64", [switch]$SkipTests)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if (-not $SkipTests) {
    Write-Host "Running the tests..."
    dotnet test StreamSetu.Core.Tests -c Release
    if ($LASTEXITCODE -ne 0) { throw "The tests failed. Nothing was built." }
}

$platform = if ($Arch -eq "x64") { "x64" } else { "ARM64" }
if (-not (Test-Path "StreamSetu.App\libmpv\$platform\libmpv-2.dll")) { throw "libmpv-2.dll is missing. Run Scripts\fetch-libmpv.ps1 first." }

$out = Join-Path $root "dist\$Arch"
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
dotnet publish StreamSetu.App -c Release -r "win-$Arch" -p:Platform=$platform -o $out
if ($LASTEXITCODE -ne 0) { throw "The build failed." }
Write-Host "Built: $out\StreamSetu.exe"
