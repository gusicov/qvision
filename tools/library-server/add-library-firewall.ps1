# QVision Library: allow the headset to reach the library server on this PC.
# Run ONCE, as administrator:
#   powershell -ExecutionPolicy Bypass -File add-library-firewall.ps1
# Adds an inbound rule for TCP 8770, Private profile only, from the local subnet only,
# in the same group as the CloudXR rules ("QVision CloudXR").

$ErrorActionPreference = 'Stop'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Please run this script as administrator (right-click PowerShell > Run as administrator).' -ForegroundColor Yellow
    exit 1
}

$name  = 'QVision Library (TCP 8770)'
$group = 'QVision CloudXR'

$existing = Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Rule '$name' already exists: updating it."
    $existing | Remove-NetFirewallRule
}

New-NetFirewallRule `
    -DisplayName $name `
    -Group $group `
    -Description 'QVision Library: lets the Vision Pro download baked Rendered scenes from this PC (LAN only).' `
    -Direction Inbound `
    -Action Allow `
    -Protocol TCP `
    -LocalPort 8770 `
    -Profile Private `
    -RemoteAddress LocalSubnet | Out-Null

Write-Host "Added firewall rule '$name' (Private profile, LocalSubnet, TCP 8770) in group '$group'." -ForegroundColor Green
Write-Host 'Make sure your Wi-Fi network is set to Private (Settings > Network & internet > Wi-Fi > your network).'
