# =============================================================================
# BAUER GROUP XPD-RPIImage - tools container launcher (PowerShell)
# =============================================================================
param(
    [Parameter(Position=0)]
    [ValidateSet("validate", "render", "build", "shell", "clean", "help")]
    [string]$Command = "help",

    [Parameter(Position=1)]
    [string]$Variant,

    [Alias("b")]
    [switch]$Build,

    [string]$EnvFile
)

$ErrorActionPreference = "Stop"

$ToolsDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir = Split-Path -Parent $ToolsDir
$ImageName  = if ($env:BGRPIIMAGE_TOOLS_IMAGE) { $env:BGRPIIMAGE_TOOLS_IMAGE } else { "bgrpiimage-tools" }

function Info  ($m) { Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Fail  ($m) { Write-Host "[ERROR] $m" -ForegroundColor Red; exit 1 }

try { docker info *>$null } catch { Fail "Docker is not running. Please start Docker Desktop first." }
if ($LASTEXITCODE -ne 0) { Fail "Docker is not running. Please start Docker Desktop first." }

function Show-Help {
@"
Usage: .\run.ps1 <command> [options]

Commands:
  validate [-Variant <name>]    Validate JSON (default: all variants)
  render    -Variant <name>     Render CustomPiOS module artifacts
  build     -Variant <name>     Full image build (privileged sibling container)
  shell                         Interactive bash inside tools container
  clean                         Wipe generated + build workspace
  help                          Show this help

Options:
  -Build, -b                    Rebuild tools image before running
  -EnvFile <path>               Pass .env to generator / build

Examples:
  .\run.ps1 validate
  .\run.ps1 render   -Variant canbus-plattform
  .\run.ps1 build    -Variant canbus-plattform -EnvFile ..\.env
  .\run.ps1 shell    -Build
"@ | Write-Host
    exit 0
}

if ($Command -eq "help") { Show-Help }

# Mirror requirements.txt so Docker COPY can see it.
Copy-Item -Force "$ProjectDir/scripts/requirements.txt" "$ToolsDir/requirements.txt"

$imageExists = $false
try { docker image inspect $ImageName *>$null; $imageExists = ($LASTEXITCODE -eq 0) } catch { $imageExists = $false }
if ($Build -or -not $imageExists) {
    Info "building tools image '$ImageName'..."
    docker build -t $ImageName $ToolsDir
    if ($LASTEXITCODE -ne 0) { Fail "failed to build tools image" }
}

$runArgs = @("--rm", "-v", "${ProjectDir}:/workspace", "-w", "/workspace")
if ($Command -in @("build", "shell")) {
    $runArgs += @("-v", "/var/run/docker.sock:/var/run/docker.sock")
}
if ($Command -eq "shell") { $runArgs += "-it" }

$pyEnvArgs = @()
if ($EnvFile) {
    if (-not (Test-Path $EnvFile)) { Fail "env file not found: $EnvFile" }
    Copy-Item -Force $EnvFile "$ProjectDir/.env"
    $runArgs += @("--env-file", $EnvFile)
    $pyEnvArgs = @("--env-file", ".env")
}

switch ($Command) {
    "validate" {
        if ($Variant) {
            docker run @runArgs $ImageName python scripts/generate.py "config/variants/$Variant.json" --dry-run | Out-Null
            Info "ok: $Variant"
        } else {
            docker run @runArgs $ImageName bash -c @'
set -e
for f in config/variants/*.json; do
    echo -e "\033[0;36m-- $f --\033[0m"
    python scripts/generate.py "$f" --dry-run > /dev/null
    echo -e "\033[0;32mok\033[0m"
done
'@
        }
    }
    "render" {
        if (-not $Variant) { Fail "render needs -Variant <name>" }
        docker run @runArgs $ImageName python scripts/generate.py "config/variants/$Variant.json" @pyEnvArgs
    }
    "build" {
        if (-not $Variant) { Fail "build needs -Variant <name>" }
        Info "building image for variant '$Variant' (privileged sibling container)"
        if ($EnvFile) {
            docker run @runArgs $ImageName bash scripts/build.sh --env-file .env $Variant
        } else {
            docker run @runArgs $ImageName bash scripts/build.sh $Variant
        }
    }
    "shell" {
        Write-Host "-------------------------------------------" -ForegroundColor Green
        Write-Host " bgRPIImage tools container"               -ForegroundColor Green
        Write-Host "-------------------------------------------" -ForegroundColor Green
        Write-Host "  make validate             validate all variants"
        Write-Host "  make render VARIANT=...   render generated files"
        Write-Host "  make build   VARIANT=...  full image build"
        Write-Host "  exit                      leave container"
        Write-Host "-------------------------------------------" -ForegroundColor Green
        docker run @runArgs $ImageName
    }
    "clean" {
        docker run @runArgs $ImageName make clean
    }
}
