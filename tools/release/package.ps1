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
    # The app expects the engine host next to the exe; media tools
    # are bundled after step 4 stages them (see below).
    Copy-Item "$root/$Out/jjamidm-engine-host.exe" `
      "$root/$Out/desktop/" -ErrorAction SilentlyContinue
  }
  Pop-Location
} else {
  Write-Warning "flutter not on PATH — desktop not packaged"
}

# 4. media tool binaries — ship alongside the app so media
#    downloads work before component-manager channels exist.
#    Mirror engine-host's findUnderTools: flat <name>, <vendor>/<name>,
#    <vendor>/bin/<name>, <vendor>/<ver>/bin/<name>.
function Find-UnderTools([string]$Dir, [string]$Name) {
  if (-not (Test-Path $Dir)) { return $null }
  $flat = Join-Path $Dir $Name
  if (Test-Path $flat) { return $flat }
  foreach ($vendor in (Get-ChildItem -Directory $Dir -ErrorAction SilentlyContinue)) {
    foreach ($cand in @((Join-Path $vendor.FullName $Name),
                        (Join-Path $vendor.FullName "bin/$Name"))) {
      if (Test-Path $cand) { return $cand }
    }
    foreach ($inner in (Get-ChildItem -Directory $vendor.FullName -ErrorAction SilentlyContinue)) {
      $cand = Join-Path $inner.FullName "bin/$Name"
      if (Test-Path $cand) { return $cand }
    }
  }
  return $null
}
$ToolsDir = "$PSScriptRoot/../../../.tools"
$ComponentOut = "$root/$Out/components"
New-Item -ItemType Directory -Force -Path $ComponentOut | Out-Null
$Ytdlp = Find-UnderTools $ToolsDir 'yt-dlp.exe'
$Ffmpeg = Find-UnderTools $ToolsDir 'ffmpeg.exe'
if ($Ytdlp) { Copy-Item $Ytdlp $ComponentOut } else {
  Write-Warning "yt-dlp.exe not under $ToolsDir — packaged media downloads won't work"
}
if ($Ffmpeg) {
  Copy-Item $Ffmpeg $ComponentOut
  $probe = Join-Path (Split-Path $Ffmpeg) 'ffprobe.exe'
  if (Test-Path $probe) { Copy-Item $probe $ComponentOut }
} else {
  Write-Warning "ffmpeg.exe not under $ToolsDir — packaged media downloads won't work"
}

# 4b. The browser-spawned engine runs from desktop\ — it resolves
#     tools at <exeDir>\components, so the staged set must ship there
#     too. This copy must run AFTER step 4: on a clean build
#     $ComponentOut doesn't exist until now. Remove a stale dest
#     first — Copy-Item into an existing dir would nest
#     components\components and the engine resolves nothing.
if (Test-Path "$root/$Out/desktop/jjamidm-engine-host.exe") {
  $dest = "$root/$Out/desktop/components"
  if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
  Copy-Item -Recurse -Force $ComponentOut $dest
}

# 5. browser extension (loaded unpacked / developer mode)
if (Test-Path "$root/$Out/browser-extension") {
  Remove-Item -Recurse -Force "$root/$Out/browser-extension"
}
Copy-Item -Recurse "$root/browser-extension" "$root/$Out/browser-extension"
Copy-Item "$root/native-host/manifest/ai.jjam.idm.json" `
  "$root/$Out/browser-extension/native-host-manifest.json" -ErrorAction SilentlyContinue

# 6. integrity manifest — every shipped artifact hashed.
#    (exclude the manifest itself — a stale copy from a previous
#    packaging run would otherwise be hashed into itself)
$manifest = @{}
Get-ChildItem -Recurse -File "$root/$Out" |
  Where-Object { $_.Name -ne 'SHA256SUMS.json' } | ForEach-Object {
  $rel = $_.FullName.Substring("$root/$Out".Length + 1)
  $manifest[$rel] = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower()
}
$manifest | ConvertTo-Json | Set-Content "$root/$Out/SHA256SUMS.json"
Write-Host "wrote $root/$Out  ($(($manifest.Keys).Count) files)" -ForegroundColor Green
