@echo off
rem QVision Environments: one baked, unlit package per room (viewing area + far-field panorama).
rem   Bake-Environment.cmd <config.json> <room ids, comma separated | all> [first-stage] [last-stage]
rem   stages per room: env_vis env_uv env_bake env_post env_pano env_export env_verify
rem   env_prep (once per project) runs first when first-stage is "env_prep" or the base blend is missing.
rem   e.g.  Bake-Environment.cmd my_project.json 01,02
rem         Bake-Environment.cmd my_project.json 03 env_post        (re-tone-map, pano, export, verify)
setlocal EnableDelayedExpansion
set "HERE=%~dp0"
if "%BLENDER%"=="" set "BLENDER=C:\Program Files\Blender Foundation\Blender 5.2\blender.exe"
set "CONFIG=%~1"
if not exist "%CONFIG%" if exist "%HERE%%CONFIG%" set "CONFIG=%HERE%%CONFIG%"
if not exist "%CONFIG%" (
  echo Config not found: %CONFIG%
  exit /b 1
)
set "ROOMS=%~2"
if "%ROOMS%"=="" set "ROOMS=all"
set "FIRST=%~3"
if "%FIRST%"=="" set "FIRST=env_vis"
set "LAST=%~4"
if "%LAST%"=="" set "LAST=env_verify"

if /I "%ROOMS%"=="all" (
  for /f "usebackq delims=" %%R in (`python -c "import json,sys;print(','.join(r['id'] for r in json.load(open(sys.argv[1],encoding='utf-8'))['rooms']))" "%CONFIG%"`) do set "ROOMS=%%R"
)
if /I "%FIRST%"=="env_prep" (
  echo ===== env_prep =====
  "%BLENDER%" -b --python-exit-code 1 --python "%HERE%qv_env.py" -- env_prep --config "%CONFIG%" || exit /b 1
  set "FIRST=env_vis"
)

for %%R in (%ROOMS:,= %) do (
  set RUN=0
  for %%S in (env_vis env_uv env_bake env_post env_pano env_export env_verify) do (
    if /I "%%S"=="!FIRST!" set RUN=1
    if !RUN!==1 (
      echo.
      echo ===== room %%R: %%S =====
      if /I "%%S"=="env_verify" (
        "%BLENDER%" -b --factory-startup --python-exit-code 1 --python "%HERE%qv_env.py" -- %%S --config "%CONFIG%" --room %%R
      ) else (
        "%BLENDER%" -b --python-exit-code 1 --python "%HERE%qv_env.py" -- %%S --config "%CONFIG%" --room %%R
      )
      if errorlevel 1 (
        echo Room %%R stage %%S FAILED
        exit /b 1
      )
    )
    if /I "%%S"=="%LAST%" set RUN=0
  )
)
echo.
echo Done. Packages and previews are in "out_dir" of %CONFIG%
endlocal
