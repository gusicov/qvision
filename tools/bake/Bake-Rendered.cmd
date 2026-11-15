@echo off
rem QVision "Rendered" bake: Blender Cycles lightmap bake -> unlit USDZ package.
rem   Bake-Rendered.cmd [config.json] [first-stage] [last-stage]
rem   stages: prep uv bake post export verify      (lookdev is manual, see README)
rem   e.g.  Bake-Rendered.cmd                       (everything, Casa SUA)
rem         Bake-Rendered.cmd casa_sua.json post     (re-tonemap after changing "exposure", then export+verify)
setlocal EnableDelayedExpansion
set "HERE=%~dp0"
if "%BLENDER%"=="" set "BLENDER=C:\Program Files\Blender Foundation\Blender 5.2\blender.exe"
set "CONFIG=%~1"
if "%CONFIG%"=="" set "CONFIG=%HERE%casa_sua.json"
if not exist "%CONFIG%" if exist "%HERE%%CONFIG%" set "CONFIG=%HERE%%CONFIG%"
set "FIRST=%~2"
if "%FIRST%"=="" set "FIRST=prep"
set "LAST=%~3"
if "%LAST%"=="" set "LAST=verify"

set RUN=0
for %%S in (prep uv bake post export verify) do (
  if /I "%%S"=="%FIRST%" set RUN=1
  if !RUN!==1 (
    echo.
    echo ===== %%S =====
    if /I "%%S"=="verify" (
      "%BLENDER%" -b --factory-startup --python-exit-code 1 --python "%HERE%qv_bake.py" -- %%S --config "%CONFIG%"
    ) else (
      "%BLENDER%" -b --python-exit-code 1 --python "%HERE%qv_bake.py" -- %%S --config "%CONFIG%"
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
