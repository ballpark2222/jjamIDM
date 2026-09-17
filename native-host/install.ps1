# Registers the FreeDM native messaging host for Chrome and Edge.
# Run once after installing jjamidm_native_host.exe + manifest.
# Usage: powershell -File install.ps1 [-ManifestPath <path>]
param(
  [string]$ManifestPath = "$PSScriptRoot\manifest\ai.jjam.idm.json"
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $ManifestPath)) {
  throw "manifest not found: $ManifestPath"
}
$ManifestPath = (Resolve-Path $ManifestPath).Path

# Per-user registration — no admin needed (design: HKCU only).
foreach ($browser in @('Google\Chrome', 'Microsoft\Edge')) {
  $key = "HKCU:\Software\$browser\NativeMessagingHosts\ai.jjam.idm"
  New-Item -Path $key -Force | Out-Null
  Set-ItemProperty -Path $key -Name '(Default)' -Value $ManifestPath
  Write-Output "registered $browser -> $ManifestPath"
}
Write-Output 'done. Reload the extension; the host launches on demand.'
