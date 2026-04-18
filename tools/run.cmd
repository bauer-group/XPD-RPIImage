@echo off
REM =============================================================================
REM BAUER GROUP XPD-RPIImage - tools container launcher (Windows CMD)
REM =============================================================================
setlocal enabledelayedexpansion

set "TOOLS_DIR=%~dp0"
set "TOOLS_DIR=%TOOLS_DIR:~0,-1%"
for %%I in ("%TOOLS_DIR%\..") do set "PROJECT_DIR=%%~fI"

if not defined BGRPIIMAGE_TOOLS_IMAGE set "BGRPIIMAGE_TOOLS_IMAGE=bgrpiimage-tools"
set "IMAGE_NAME=%BGRPIIMAGE_TOOLS_IMAGE%"

docker info >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Docker is not running. Please start Docker Desktop first.
    exit /b 1
)

set "COMMAND="
set "VARIANT="
set "BUILD_IMAGE=false"
set "ENV_FILE="

:parse
if "%~1"=="" goto :done
if /i "%~1"=="validate" (set "COMMAND=validate" & shift & goto :parse)
if /i "%~1"=="render"   (set "COMMAND=render"   & shift & goto :parse)
if /i "%~1"=="build"    (set "COMMAND=build"    & shift & goto :parse)
if /i "%~1"=="shell"    (set "COMMAND=shell"    & shift & goto :parse)
if /i "%~1"=="clean"    (set "COMMAND=clean"    & shift & goto :parse)
if /i "%~1"=="help"     (goto :help)
if /i "%~1"=="--help"   (goto :help)
if /i "%~1"=="-h"       (goto :help)
if /i "%~1"=="--build"  (set "BUILD_IMAGE=true" & shift & goto :parse)
if /i "%~1"=="-b"       (set "BUILD_IMAGE=true" & shift & goto :parse)
if /i "%~1"=="--env-file" (set "ENV_FILE=%~2" & shift & shift & goto :parse)
if not defined VARIANT (set "VARIANT=%~1" & shift & goto :parse)
echo [ERROR] Unknown arg: %~1
goto :help

:done
if "%COMMAND%"=="" goto :help

REM Ensure requirements.txt mirror is fresh before build.
copy /Y "%PROJECT_DIR%\scripts\requirements.txt" "%TOOLS_DIR%\requirements.txt" >nul

docker image inspect %IMAGE_NAME% >nul 2>&1
if errorlevel 1 set "BUILD_IMAGE=true"

if /i "%BUILD_IMAGE%"=="true" (
    echo [INFO] building tools image '%IMAGE_NAME%'...
    docker build -t %IMAGE_NAME% "%TOOLS_DIR%"
    if errorlevel 1 (
        echo [ERROR] failed to build tools image
        exit /b 1
    )
)

set "RUN_FLAGS=--rm -v "%PROJECT_DIR%:/workspace" -w /workspace"
if /i "%COMMAND%"=="build" set "RUN_FLAGS=%RUN_FLAGS% -v /var/run/docker.sock:/var/run/docker.sock"
if /i "%COMMAND%"=="shell" set "RUN_FLAGS=%RUN_FLAGS% -v /var/run/docker.sock:/var/run/docker.sock -it"

set "PY_ENV_ARGS="
if defined ENV_FILE (
    if not exist "%ENV_FILE%" (
        echo [ERROR] env file not found: %ENV_FILE%
        exit /b 1
    )
    copy /Y "%ENV_FILE%" "%PROJECT_DIR%\.env" >nul
    set "RUN_FLAGS=%RUN_FLAGS% --env-file "%ENV_FILE%""
    set "PY_ENV_ARGS=--env-file .env"
)

if /i "%COMMAND%"=="validate" (
    if defined VARIANT (
        docker run %RUN_FLAGS% %IMAGE_NAME% python scripts/generate.py "config/variants/%VARIANT%.json" --dry-run >nul
        echo [INFO] ok: %VARIANT%
    ) else (
        docker run %RUN_FLAGS% %IMAGE_NAME% bash -c "set -e; for f in config/variants/*.json; do echo \"-- $f --\"; python scripts/generate.py \"$f\" --dry-run > /dev/null; echo ok; done"
    )
    goto :eof
)

if /i "%COMMAND%"=="render" (
    if not defined VARIANT (echo [ERROR] render needs a variant name & exit /b 1)
    docker run %RUN_FLAGS% %IMAGE_NAME% python scripts/generate.py "config/variants/%VARIANT%.json" %PY_ENV_ARGS%
    goto :eof
)

if /i "%COMMAND%"=="build" (
    if not defined VARIANT (echo [ERROR] build needs a variant name & exit /b 1)
    echo [INFO] building image for variant '%VARIANT%'...
    if defined ENV_FILE (
        docker run %RUN_FLAGS% %IMAGE_NAME% bash scripts/build.sh --env-file .env "%VARIANT%"
    ) else (
        docker run %RUN_FLAGS% %IMAGE_NAME% bash scripts/build.sh "%VARIANT%"
    )
    goto :eof
)

if /i "%COMMAND%"=="shell" (
    echo -------------------------------------------
    echo  bgRPIImage tools container
    echo -------------------------------------------
    echo   make validate             validate all variants
    echo   make render VARIANT=...   render generated files
    echo   make build VARIANT=...    full image build
    echo   exit                      leave container
    echo -------------------------------------------
    docker run %RUN_FLAGS% %IMAGE_NAME%
    goto :eof
)

if /i "%COMMAND%"=="clean" (
    docker run %RUN_FLAGS% %IMAGE_NAME% make clean
    goto :eof
)

:help
echo Usage: run.cmd ^<command^> [options]
echo.
echo Commands:
echo   validate [variant]      Validate JSON (default: all variants)
echo   render ^<variant^>        Render CustomPiOS module artifacts
echo   build ^<variant^>         Full image build
echo   shell                   Interactive bash inside tools container
echo   clean                   Wipe generated + build workspace
echo   help                    Show this help
echo.
echo Options:
echo   --build, -b             Rebuild tools image before running
echo   --env-file ^<path^>       Pass .env to generator / build
echo.
echo Examples:
echo   run.cmd validate
echo   run.cmd render canbus-plattform
echo   run.cmd build canbus-plattform --env-file ..\.env
echo   run.cmd shell -b
exit /b 0
endlocal
