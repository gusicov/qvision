@echo off
rem QVision "Rendered HD": albedo x lightmap package, built on top of a finished v1 bake (Bake-Rendered.cmd).
rem   Bake-Rendered-HD.cmd [config.json] [first-stage] [last-stage]
rem   stages: hd_prep hd_light hd_export hd_verify
rem   e.g.  Bake-Rendered-HD.cmd                          (everything, Casa SUA)
rem         Bake-Rendered-HD.cmd casa_sua.json hd_light    (new lightmaps / tone fit, then export + verify)
setlocal EnableDelayedExpansion
set "HERE=%~dp0"
if "%BLENDER%"=="" set "BLENDER=C:\Program Files\Blender Foundation\Blender 5.2\blender.exe"
set "CONFIG=%~1"
if "%CONFIG%"=="" set "CONFIG=%HERE%casa_sua.json"
if not exist "%CONFIG%" if exist "%HERE%%CONFIG%" set "CONFIG=%HERE%%CONFIG%"
set "FIRST=%~2"
if "%FIRST%"=="" set "FIRST=hd_prep"
set "LAST=%~3"
if "%LAST%"=="" set "LAST=hd_verify"

set RUN=0
for %%S in (hd_prep hd_light hd_export hd_verify) do (
  if /I "%%S"=="%FIRST%" set RUN=1
  if !RUN!==1 (
    echo.
    echo ===== %%S =====
    if /I "%%S"=="hd_verify" (
      "%BLENDER%" -b --factory-startup --python-exit-code 1 --python "%HERE%qv_hd.py" -- %%S --config "%CONFIG%"
    ) else (
      "%BLENDER%" -b --python-exit-code 1 --python "%HERE%qv_hd.py" -- %%S --config "%CONFIG%"
    )
    if errorlevel 1 (
      echo Stage %%S FAILED
      exit /b 1
    )
  )
  if /I "%%S"=="%LAST%" set RUN=0
)
echo.
echo Done. Output folder is "out_dir" in %CONFIG%
endlocal
