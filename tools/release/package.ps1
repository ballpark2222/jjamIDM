# jjamIDM RC packaging (design doc §23, M15).
# Produces release/jjamidm-rc/ with binaries, extension, manifests,
# and a sha256 integrity manifest. Run from the repo root:
#   powershell -File tools/release/package.ps1
param(
  [string]$Out = "release/jjamidm-rc",
  [string]$Dart = "$PSScriptRoot/../../../.tools/dart-sdk/bin/dart.exe",
  [string]$Cargo = "$env:USERPROFILE\.cargo\bin\cargo.exe"
)
$ErrorActionPreference = "Stop"
$root = Resolve-Path "$PSScriptRoot/../.."
$sep = [IO.Path]::DirectorySeparatorChar

Write-Host "== jjamIDM RC packaging ==" -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path "$root/$Out" | Out-Null

# 1. native host (Rust)
Push-Location "$root/native-host"
& $Cargo build --release
Copy-Item "target/release/jjamidm_native_host.exe" "$root/$Out/"
Pop-Location

# 2. engine host (AOT dart)
& $Dart compile exe "$root/apps/engine-host/bin/main.dart" `
  -o "$root/$Out/jjamidm-engine-host.exe"

# 3. desktop app — requires Visual Studio C++ workload.
$Flutter = "$PSScriptRoot/../../../.tools/flutter/bin/flutter.bat"
if (-not (Get-Command flutter -ErrorAction SilentlyContinue) -and (Test-Path $Flutter)) {
  $env:PATH = (Split-Path $Flutter) + ";" + $env:PATH
}
if (Get-Command flutter -ErrorAction SilentlyContinue) {
  Push-Location "$root/apps/desktop"
  try { flutter build windows --release } catch {
    Write-Warning "desktop build skipped: $_"
  }
  if (Test-Path "build/windows/x64/runner/Release/jjamidm.exe") {
    # Copy the Release dir wholesale — the runner expects its data/
    # subdir (app.so, icudtl.dat, flutter_assets) intact.
    if (Test-Path "$root/$Out/desktop") {
      Remove-Item -Recurse -Force "$root/$Out/desktop"
    }
    Copy-Item -Recurse "build/windows/x64/runner/Release" `
      "$root/$Out/desktop"
    # The app expects the engine host + media tools next to the exe.
    Copy-Item "$root/$Out/jjamidm-engine-host.exe" `
      "$root/$Out/desktop/" -ErrorAction SilentlyContinue
    if (Test-Path "$root/$Out/components") {
      Copy-Item -Recurse "$root/$Out/components" `
        "$root/$Out/desktop/components"
    }
  }
  Pop-Location
} else {
  Write-Warning "flutter not on PATH — desktop not packaged"
}

# 4. media tool binaries — ship alongside the app so media
#    downloads work before component-manager channels exist.
$ToolsDir = "$PSScriptRoot/../../../.tools"
$ComponentOut = "$root/$Out/components"
New-Item -ItemType Directory -Force -Path $ComponentOut | Out-Null
if (Test-Path "$ToolsDir/yt-dlp.exe") {
  Copy-Item "$ToolsDir/yt-dlp.exe" $ComponentOut
}
$FfmpegBin = "$ToolsDir/ffmpeg-extract/ffmpeg-9.0.1-essentials_build/bin"
if (Test-Path $FfmpegBin) {
  Copy-Item "$FfmpegBin/ffmpeg.exe","$FfmpegBin/ffprobe.exe" $ComponentOut -ErrorAction SilentlyContinue
}

# 5. browser extension (loaded unpacked / developer mode)
if (Test-Path "$root/$Out/browser-extension") {
  Remove-Item -Recurse -Force "$root/$Out/browser-extension"
}
Copy-Item -Recurse "$root/browser-extension" "$root/$Out/browser-extension"
Copy-Item "$root/native-host/manifest/ai.jjam.idm.json" `
  "$root/$Out/browser-extension/native-host-manifest.json" -ErrorAction SilentlyContinue

# 6. integrity manifest — every shipped artifact hashed.
$manifest = @{}
Get-ChildItem -Recurse -File "$root/$Out" | ForEach-Object {
  $rel = $_.FullName.Substring("$root/$Out".Length + 1)
  $manifest[$rel] = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower()
}
$manifest | ConvertTo-Json | Set-Content "$root/$Out/SHA256SUMS.json"
Write-Host "wrote $root/$Out  ($(($manifest.Keys).Count) files)" -ForegroundColor Green
