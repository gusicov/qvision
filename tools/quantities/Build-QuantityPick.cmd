@echo off
rem QVision v0.11.1: write Data\pick.json + Data\pick.bin (tap picking) for quantity packages.
rem   Build-QuantityPick.cmd <package dir> [<package dir> ...]
rem   With no argument: every package folder (with a manifest.json) under assets\Quantities\*\*.
rem   Afterwards restart "QVision Library (PC)" so /quantities.json lists the new files.
setlocal EnableDelayedExpansion
set "HERE=%~dp0"
if "%BLENDER%"=="" set "BLENDER=C:\Program Files\Blender Foundation\Blender 5.2\blender.exe"
set "PACKAGES="
if "%~1"=="" (
  for /d %%A in ("%HERE%..\..\..\assets\Quantities\*") do (
    for /d %%P in ("%%~fA\*") do if exist "%%~fP\manifest.json" set PACKAGES=!PACKAGES! "%%~fP"
  )
) else (
  set PACKAGES=%*
)
if "!PACKAGES!"=="" (
  echo No package folders found.
  exit /b 1
)
"%BLENDER%" -b --factory-startup --python-exit-code 1 --python "%HERE%qv_pick.py" -- !PACKAGES! || exit /b 1
endlocal
