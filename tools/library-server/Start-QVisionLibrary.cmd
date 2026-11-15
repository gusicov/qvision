@echo off
setlocal
title QVision Library (PC)
rem Serves the baked Rendered scenes in "C:\All Docs\06_Apple vision pro\assets\Rendered"
rem to QVision on the Vision Pro (Home > Rendered > On my PC). LAN only, TCP port 8770.

set "LIBRARY=C:\All Docs\06_Apple vision pro\assets\Rendered"
set "PORT=8770"
set "SCRIPT=%~dp0qvision_library.py"

echo.
echo  QVision Library
echo  ===============
echo  Folder: %LIBRARY%
echo.
echo  This PC's LAN address(es) - type one into QVision ^> Rendered ^> On my PC:
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.AddressState -eq 'Preferred' } | Sort-Object InterfaceMetric; if (-not $ips) { Write-Host '    (none found - run ipconfig)' } else { foreach ($ip in $ips) { Write-Host ('    {0,-16} http://{0}:%PORT%/index.json   ({1})' -f $ip.IPAddress, $ip.InterfaceAlias) } }"
echo.
echo  First time only: run add-library-firewall.ps1 as administrator (allows TCP %PORT% on Private networks).
echo  Keep this window open while the headset downloads. Ctrl+C or close the window to stop.
echo.

where py >nul 2>nul
if %ERRORLEVEL%==0 (
    py -3 "%SCRIPT%" "%LIBRARY%" --port %PORT%
) else (
    python "%SCRIPT%" "%LIBRARY%" --port %PORT%
)
echo.
echo  QVision Library stopped.
pause
