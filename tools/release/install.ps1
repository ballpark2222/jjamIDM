# jjamIDM one-shot installer (dev/RC channel).
#   1. Writes the native-messaging host manifest pointing at the
#      packaged jjamidm_native_host.exe.
#   2. Writes %APPDATA%\jjamIDM\native-host.json (engine command,
#      download dir, queue settings) — the host cold-launches
#      jjamidm-engine-host.exe in queue mode (scheduler-backed).
#   3. Registers the host for Chrome + Edge under HKCU (no admin).
#
# The browser extension carries a fixed `key`, so its ID is
# deterministic: lfgbaljhboceihkklkifpfbengheamdo
#
# Usage: powershell -File tools/release/install.ps1
#          [-RcDir <path>] [-ExtensionId <id>]
param(
  [string]$RcDir = "$PSScriptRoot\..\..\release\jjamidm-rc",
  [string]$ExtensionId = 'lfgbaljhboceihkklkifpfbengheamdo',
  [string]$DownloadDir = "$env:USERPROFILE\Downloads\jjamIDM"
)
$ErrorActionPreference = 'Stop'
$RcDir = (Resolve-Path $RcDir).Path
$sep = [IO.Path]::DirectorySeparatorChar

$hostExe  = "$RcDir\jjamidm_native_host.exe"
$engineExe = "$RcDir\desktop\jjamidm-engine-host.exe"
foreach ($f in @($hostExe, $engineExe)) {
  if (-not (Test-Path $f)) { throw "missing artifact: $f (run package.ps1 first)" }
}
# Host reads %APPDATA%\jjamIDM\native-host.json; engine/desktop data
# lives under %LOCALAPPDATA%\jjamIDM.
$configDir = "$env:APPDATA\jjamIDM"
$dataDir = "$env:LOCALAPPDATA\jjamIDM"

# 1. host manifest — absolute exe path + pinned extension origin.
$manifest = [ordered]@{
  name = 'ai.jjam.idm'
  description = 'jjamIDM native messaging host'
  path = $hostExe
  type = 'stdio'
  allowed_origins = @("chrome-extension://$ExtensionId/")
}
$manifestPath = "$RcDir\native-host-manifest.json"
# No BOM — serde_json rejects it.
[IO.File]::WriteAllText($manifestPath,
  ($manifest | ConvertTo-Json),
  [Text.UTF8Encoding]::new($false))
Write-Output "wrote $manifestPath"

# 2. host config — engine spawn argv + download dir.
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
$config = [ordered]@{
  allowedOrigins = @("chrome-extension://$ExtensionId/")
  engineCommand = @(
    $engineExe,
    '--temp-root', "$dataDir\engine-temp",
    # Browser engine gets its own data dir — sharing
    # <dataDir>\media-tasks with the desktop's engine would put two
    # process-local JsonTaskRepository writers on one tasks.json
    # (read-modify-write → last-write-wins record loss).
    '--data-dir', "$dataDir\browser"
  )
  engineCwd = "$RcDir\desktop"
  downloadDir = $DownloadDir
  # Browser engine runs in queue mode: concurrent downloads cap +
  # persistent queue (dir defaults to <configDir>\queue).
  maxConcurrent = 3
  queueDir = "$configDir\queue"
}
$configPath = "$configDir\native-host.json"
[IO.File]::WriteAllText($configPath,
  ($config | ConvertTo-Json),
  [Text.UTF8Encoding]::new($false))
Write-Output "wrote $configPath"

# 3. registry — per-user NativeMessagingHosts (HKCU, no admin).
# Remove the legacy FreeDM key if present (renamed → ai.jjam.idm).
foreach ($browser in @('Google\Chrome', 'Microsoft\Edge')) {
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue `
    "HKCU:\Software\$browser\NativeMessagingHosts\ai.devin.freedm"
  $key = "HKCU:\Software\$browser\NativeMessagingHosts\ai.jjam.idm"
  New-Item -Path $key -Force | Out-Null
  Set-ItemProperty -Path $key -Name '(Default)' -Value $manifestPath
  Write-Output "registered $browser"
}

Write-Output ''
Write-Output 'Done. Last step is manual (Chrome requires it):'
Write-Output '  chrome://extensions → 개발자 모드 → "압축해제된 확장 로드"'
Write-Output "  → $RcDir\browser-extension"
Write-Output "  extension id will be: $ExtensionId"
