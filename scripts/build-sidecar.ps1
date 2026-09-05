# Builds the Windows Rust sidecar (engine-windows) and installs it where
# Tauri's externalBin expects it, renamed with the rustc host target-triple
# suffix. The Windows analog of build-sidecar.sh.
#
# No codesign / Info.plist embedding: those are macOS TCC concerns. Windows
# microphone access is governed by the OS privacy setting at runtime, and
# WASAPI loopback needs no special grant.
#
# Usage:  pwsh scripts/build-sidecar.ps1 [debug|release]
[CmdletBinding()]
param(
    [ValidateSet('debug', 'release')]
    [string]$Config = 'debug'
)

$ErrorActionPreference = 'Stop'

$Root    = Split-Path -Parent $PSScriptRoot
$Crate   = Join-Path $Root 'engine-windows'
$DestDir = Join-Path $Root 'app/src-tauri/binaries'

# Resolve the target triple the same way Tauri's externalBin does: the `host:`
# line from `rustc -Vv` (e.g. x86_64-pc-windows-msvc).
$Triple = (& rustc -Vv | Select-String '^host:\s*(.+)$').Matches[0].Groups[1].Value.Trim()
if (-not $Triple) { throw 'could not determine rustc host target triple' }

Write-Host "building minutiae-engine ($Config) for $Triple"

$cargoArgs = @('build', '--manifest-path', (Join-Path $Crate 'Cargo.toml'), '--target', $Triple)
if ($Config -eq 'release') { $cargoArgs += '--release' }
& cargo @cargoArgs
if ($LASTEXITCODE -ne 0) { throw "cargo build failed ($LASTEXITCODE)" }

$BuildDir = Join-Path $Crate "target/$Triple/$Config"
$SrcExe   = Join-Path $BuildDir 'minutiae-engine.exe'
$DestExe  = Join-Path $DestDir  "minutiae-engine-$Triple.exe"

New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
Copy-Item -Force $SrcExe $DestExe

# Phase 2: sherpa-onnx pulls native runtime libraries (onnxruntime.dll and,
# for the DirectML EP, the provider DLL). cargo copies them next to the built
# exe; carry them into binaries/ for packaging. (Phase 1 has no native deps, so
# this copies nothing.)
$dlls = Get-ChildItem -Path $BuildDir -Filter '*.dll' -ErrorAction SilentlyContinue
foreach ($dll in $dlls) {
    Copy-Item -Force $dll.FullName (Join-Path $DestDir $dll.Name)
    Write-Host "  bundled runtime lib: $($dll.Name)"
}
# NOTE: `tauri dev` runs the app from app/src-tauri/target/<profile>/; the DLLs
# must also sit beside the app exe there for the sidecar to load them. The dev
# task should copy them (or symlink) once Phase 2 introduces them.

Write-Host "sidecar built: $DestExe ($Config)"
