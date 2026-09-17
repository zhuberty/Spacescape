# =============================================================================
# Spacescape Windows Build Script
# =============================================================================
# Installs all prerequisites and builds Spacescape into a runnable executable.
# Run from the repository root in PowerShell.
#
# Usage:
#   .\build.ps1                  # Full build (installs deps + compiles)
#   .\build.ps1 -SkipInstall     # Skip winget/pip installs (deps already present)
#   .\build.ps1 -BuildType Release
# =============================================================================

param(
    [switch]$SkipInstall,
    [string]$BuildType = "Release",
    [string]$QtVersion = "5.12.8"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot   = $PSScriptRoot
$BuildDir   = Join-Path $RepoRoot "build"
$InstallDir = Join-Path $RepoRoot "dist"
$LibsOgre   = Join-Path $RepoRoot "libs\Ogre"
$LibsQt     = Join-Path $RepoRoot "libs\Qt"

function Write-Step([string]$msg) {
    Write-Host ""
    Write-Host "==> $msg" -ForegroundColor Cyan
}
function Assert-Ok([string]$desc) {
    if ($LASTEXITCODE -ne 0) {
        Write-Host "FAILED: $desc (exit $LASTEXITCODE)" -ForegroundColor Red
        exit $LASTEXITCODE
    }
}

# ---------------------------------------------------------------------------
# 1. Install CMake
# ---------------------------------------------------------------------------
Write-Step "Checking CMake..."
$_cmake = Get-Command cmake -ErrorAction SilentlyContinue
$cmakeExe = if ($_cmake) { $_cmake.Source } else { "C:\Program Files\CMake\bin\cmake.exe" }
if (-not (Test-Path $cmakeExe)) {
    if ($SkipInstall) { Write-Host "ERROR: cmake not found and -SkipInstall set." -ForegroundColor Red; exit 1 }
    Write-Step "Installing CMake via winget..."
    winget install --id Kitware.CMake --silent --accept-package-agreements --accept-source-agreements
    Assert-Ok "winget install CMake"
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH","User")
    $_cmake = Get-Command cmake -ErrorAction SilentlyContinue
    $cmakeExe = if ($_cmake) { $_cmake.Source } else { "C:\Program Files\CMake\bin\cmake.exe" }
}
Write-Host "  cmake: $cmakeExe"

# ---------------------------------------------------------------------------
# 2. Locate Visual Studio / MSVC Build Tools
# ---------------------------------------------------------------------------
Write-Step "Locating Visual Studio MSVC compiler..."
$vsWhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"

if (-not (Test-Path $vsWhere)) {
    Write-Host "ERROR: vswhere.exe not found. Install VS 2022 Build Tools first." -ForegroundColor Red
    Write-Host "       https://aka.ms/vs/17/release/vs_BuildTools.exe" -ForegroundColor Yellow
    exit 1
}

$vsInstallPath = (& $vsWhere -latest -products * -requires Microsoft.VisualCpp.Tools.HostX64.TargetX64 -property installationPath 2>$null)
if (-not $vsInstallPath) {
    if (-not $SkipInstall) {
        Write-Step "Installing VS 2022 Build Tools via winget..."
        winget install --id Microsoft.VisualStudio.2022.BuildTools --silent `
            --accept-package-agreements --accept-source-agreements `
            --override "--quiet --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --wait"
        Assert-Ok "winget install VS Build Tools"
        $vsInstallPath = (& $vsWhere -latest -products * -requires Microsoft.VisualCpp.Tools.HostX64.TargetX64 -property installationPath 2>$null)
    }
    if (-not $vsInstallPath) {
        Write-Host "ERROR: MSVC compiler not found. Install 'Desktop development with C++' workload." -ForegroundColor Red
        exit 1
    }
}
$vsInstallPath = $vsInstallPath.Trim()
Write-Host "  VS install: $vsInstallPath"

# ---------------------------------------------------------------------------
# 3. Bootstrap vcpkg and install Ogre 1.12
# ---------------------------------------------------------------------------
# NOTE: No pre-built Ogre 1.12 SDK binary exists for download (bintray is gone,
# GitHub releases contain only source). We use vcpkg to build Ogre from source.
Write-Step "Checking vcpkg..."
$VcpkgDir    = Join-Path $RepoRoot "vcpkg"
$VcpkgExe    = Join-Path $VcpkgDir "vcpkg.exe"
$VcpkgToolchain = Join-Path $VcpkgDir "scripts\buildsystems\vcpkg.cmake"

if (-not (Test-Path $VcpkgExe)) {
    if ($SkipInstall) { Write-Host "ERROR: vcpkg not found and -SkipInstall set." -ForegroundColor Red; exit 1 }
    Write-Step "Cloning vcpkg (full clone required for version pinning)..."
    if (Test-Path $VcpkgDir) { Remove-Item $VcpkgDir -Recurse -Force }
    git clone https://github.com/microsoft/vcpkg.git $VcpkgDir
    Assert-Ok "git clone vcpkg"
    & (Join-Path $VcpkgDir "bootstrap-vcpkg.bat") -disableMetrics
    Assert-Ok "bootstrap-vcpkg"
} else {
    # If it was previously cloned shallow, unshallow it now (required for versioning)
    $isShallow = (git -C $VcpkgDir rev-parse --is-shallow-repository 2>$null).Trim()
    if ($isShallow -eq "true") {
        Write-Step "vcpkg was cloned shallow -- fetching full history for version pinning..."
        git -C $VcpkgDir fetch --unshallow
        Assert-Ok "git fetch --unshallow vcpkg"
    } else {
        Write-Host "  vcpkg already bootstrapped: $VcpkgExe"
    }
}

# Write a vcpkg.json manifest with an override to force Ogre 1.12.9.
# vcpkg's "overrides" bypass the baseline and install the exact version requested.
# The builtin-baseline is read from the vcpkg repo HEAD we just cloned.
Write-Step "Writing vcpkg.json manifest to pin Ogre 1.12.9..."
$vcpkgManifestPath = Join-Path $RepoRoot "vcpkg.json"

# Get the baseline hash from the cloned vcpkg repo
$vcpkgBaseline = (git -C $VcpkgDir rev-parse HEAD 2>$null).Trim()
if (-not $vcpkgBaseline) { $vcpkgBaseline = "ce4a5dae13a41c3c88e0b4e8a74dd0de64e5ee1e" }
Write-Host "  Using vcpkg baseline: $vcpkgBaseline"

# Remove any wrong-version Ogre that may already be installed
Write-Step "Removing any existing Ogre installation from vcpkg..."
try { & $VcpkgExe remove "ogre:x64-windows" "--recurse" 2>&1 | Out-Null } catch {}

# Write the manifest
$manifest = @"
{
  "name": "spacescape",
  "version": "0.7.0",
  "dependencies": [
    "freetype",
    { "name": "ogre", "default-features": false, "features": ["assimp", "freeimage", "zziplib"] }
  ],
  "overrides": [
    { "name": "ogre", "version": "1.12.9", "port-version": 10 }
  ],
  "builtin-baseline": "$vcpkgBaseline"
}
"@
Set-Content -Path $vcpkgManifestPath -Value $manifest -Encoding UTF8
Write-Host "  Written: $vcpkgManifestPath"

Write-Step "Installing Ogre 1.12.9 via vcpkg manifest (builds from source - may take 15-25 min on first run)..."
# Use manifest mode: vcpkg reads vcpkg.json from the project root
& $VcpkgExe install `
    "--x-manifest-root=$RepoRoot" `
    "--x-install-root=$VcpkgDir\installed" `
    "--triplet=x64-windows"
Assert-Ok "vcpkg install ogre 1.12.9"

# ---------------------------------------------------------------------------
# 4. Install Qt 5.12.8 via aqtinstall
# ---------------------------------------------------------------------------
# Qt 5.12.8 was released before MSVC 2019 runtimes, so the arch is msvc2017_64.
# qtcore/qtgui/qtwidgets are BASE components included automatically -- do NOT
# pass them with -m (that flag is only for optional add-on modules like qtxml).
Write-Step "Checking Qt $QtVersion..."
$QtArch       = "win64_msvc2017_64"
$QtPrefixPath = Join-Path $LibsQt "$QtVersion\msvc2017_64"
$QtMarker     = Join-Path $QtPrefixPath "bin\qmake.exe"
if (-not (Test-Path $QtMarker)) {
    if ($SkipInstall) { Write-Host "ERROR: Qt missing and -SkipInstall set." -ForegroundColor Red; exit 1 }
    Write-Step "Installing Qt $QtVersion ($QtArch) via aqtinstall..."
    pip install -q aqtinstall; Assert-Ok "pip install aqtinstall"
    New-Item -ItemType Directory -Force -Path $LibsQt | Out-Null
    # All Qt5 components needed (core, gui, widgets, xml) are base packages - no -m flag needed
    python -m aqt install-qt --outputdir $LibsQt windows desktop $QtVersion $QtArch
    Assert-Ok "aqt install-qt"
} else { Write-Host "  Qt $QtVersion already installed." }
if (-not (Test-Path $QtPrefixPath)) {
    Write-Host "ERROR: Qt prefix not found: $QtPrefixPath" -ForegroundColor Red; exit 1
}

# ---------------------------------------------------------------------------
# 5. CMake Configure
# ---------------------------------------------------------------------------
# NOTE: The Visual Studio generator finds MSVC automatically via the registry -
# vcvars64 is NOT needed for cmake configure/build/install with this generator.
Write-Step "Configuring with CMake ($BuildType)..."
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null

# Always wipe the CMake cache so toolchain file and prefix path are never stale
Remove-Item (Join-Path $BuildDir "CMakeCache.txt") -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $BuildDir "CMakeFiles") -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Patch vcpkg-installed cmake config files that use bare "cmake_policy(VERSION 3)"
# which CMake 4.x rejects as syntactically invalid (requires major.minor).
# Replace all occurrences with "cmake_policy(VERSION 3.5)" across all installed share dirs.
# ---------------------------------------------------------------------------
Write-Step "Patching vcpkg cmake config files for CMake 4.x compatibility..."
$vcpkgShare = Join-Path $BuildDir "vcpkg_installed\x64-windows\share"
if (Test-Path $vcpkgShare) {
    $cmakeFiles = Get-ChildItem $vcpkgShare -Recurse -Filter "*.cmake" -File
    $patchCount = 0
    foreach ($f in $cmakeFiles) {
        $content = Get-Content $f.FullName -Raw -Encoding UTF8
        # CMake 4.x requires cmake_policy(VERSION ...) minimum >= 3.5.
        # Raise any minimum below 3.5 (covers 2.x.y and 3.0-3.4) to 3.5.
        $patched = $content -replace 'cmake_policy\(VERSION (2\.\d+\.\d+|3\.[0-4](?:\.\d+)?)(\.\.\.)','cmake_policy(VERSION 3.5$2'
        if ($patched -ne $content) {
            Set-Content $f.FullName -Value $patched -Encoding UTF8 -NoNewline
            $patchCount++
        }
    }
    Write-Host "  Patched $patchCount cmake config file(s)."
} else {
    Write-Host "  vcpkg share dir not found yet (will patch after first cmake run)." -ForegroundColor Yellow
}

& $cmakeExe $RepoRoot -B $BuildDir `
    -G "Visual Studio 17 2022" -A x64 `
    "-DCMAKE_BUILD_TYPE=$BuildType" `
    "-DCMAKE_PREFIX_PATH=$QtPrefixPath" `
    "-DCMAKE_TOOLCHAIN_FILE=$VcpkgToolchain" `
    "-DVCPKG_TARGET_TRIPLET=x64-windows" `
    "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
if ($LASTEXITCODE -ne 0) { Write-Host "FAILED: cmake configure" -ForegroundColor Red; exit $LASTEXITCODE }

# ---------------------------------------------------------------------------
# 6. CMake Build
# ---------------------------------------------------------------------------
Write-Step "Building..."
& $cmakeExe --build $BuildDir --config $BuildType --parallel
if ($LASTEXITCODE -ne 0) { Write-Host "FAILED: cmake build" -ForegroundColor Red; exit $LASTEXITCODE }

# ---------------------------------------------------------------------------
# 7. CMake Install
# ---------------------------------------------------------------------------
Write-Step "Installing to $InstallDir..."
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
& $cmakeExe --install $BuildDir --prefix $InstallDir --config $BuildType
if ($LASTEXITCODE -ne 0) { Write-Host "FAILED: cmake install" -ForegroundColor Red; exit $LASTEXITCODE }

# ---------------------------------------------------------------------------
# 8. Deploy Qt DLLs with windeployqt
# ---------------------------------------------------------------------------
Write-Step "Deploying Qt runtime DLLs..."
$spacescapeExe = Join-Path $InstallDir "Spacescape.exe"
$windeployqt   = Join-Path $QtPrefixPath "bin\windeployqt.exe"
if ((Test-Path $windeployqt) -and (Test-Path $spacescapeExe)) {
    & $windeployqt --no-translations --no-angle --no-opengl-sw $spacescapeExe
} else {
    Write-Host "  WARNING: skipping windeployqt (exe or tool not found)" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 9. Copy Ogre runtime DLLs + SpacescapePlugin
# ---------------------------------------------------------------------------
Write-Step "Copying Ogre runtime DLLs..."
# vcpkg manifest mode installs DLLs to build/vcpkg_installed/x64-windows/bin
# (classic mode uses vcpkg/installed/x64-windows/bin - check both)
$OgreBin = Join-Path $BuildDir "vcpkg_installed\x64-windows\bin"
if (-not (Test-Path $OgreBin)) {
    $OgreBin = Join-Path $VcpkgDir "installed\x64-windows\bin"
}
if (Test-Path $OgreBin) {
    # Copy ALL DLLs (Ogre plugins + their dependencies like freetype, libpng, zlib, etc.)
    Get-ChildItem $OgreBin -Filter "*.dll" -File | ForEach-Object {
        Copy-Item $_.FullName -Destination $InstallDir -Force
        Write-Host "  $($_.Name)"
    }
} else {
    Write-Host "  WARNING: vcpkg Ogre bin not found at $OgreBin" -ForegroundColor Yellow
}
Get-ChildItem (Join-Path $BuildDir "src\SpacescapePlugin\$BuildType") -Filter "*.dll" -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-Item $_.FullName -Destination $InstallDir -Force
    Write-Host "  $($_.Name)"
}

# ---------------------------------------------------------------------------
# 10. Copy app config and media assets
# ---------------------------------------------------------------------------
Write-Step "Copying app configs and media..."
$shareWin = Join-Path $RepoRoot "share\app\win"
if (Test-Path $shareWin) { Get-ChildItem $shareWin | Copy-Item -Destination $InstallDir -Force }
foreach ($sub in @("media","save")) {
    $src = Join-Path $RepoRoot "share\$sub"
    if (Test-Path $src) { Copy-Item $src -Destination $InstallDir -Recurse -Force }
}

# ---------------------------------------------------------------------------
# 11. Create plugins.cfg at repo root (app looks for ../plugins.cfg from dist/)
# ---------------------------------------------------------------------------
Write-Step "Creating plugins.cfg..."
$pluginsCfg = Join-Path $RepoRoot "plugins.cfg"
$distAbsPath = $InstallDir.Replace('\', '\\')
Set-Content $pluginsCfg @"
# Defines plugins to load
# PluginFolder uses absolute path because the app's CWD is dist/ but
# plugins.cfg is resolved from dist/../plugins.cfg (the repo root).
PluginFolder=$InstallDir

# Define plugins
Plugin=RenderSystem_GL
Plugin=RenderSystem_GL3Plus
Plugin=RenderSystem_Direct3D11
Plugin=Plugin_ParticleFX
Plugin=Plugin_BSPSceneManager
Plugin=Plugin_PCZSceneManager
Plugin=Plugin_OctreeZone
Plugin=Plugin_OctreeSceneManager
Plugin=Plugin_DotScene
Plugin=Plugin_Spacescape
Plugin=Codec_STBI
"@
Write-Host "  $pluginsCfg"

# Also create resources.cfg at repo root (app looks for ../resources.cfg from dist/)
$resourcesCfg = Join-Path $RepoRoot "resources.cfg"
Set-Content $resourcesCfg @"
# Resource locations to be added to the default path
# Paths are relative to the app CWD (dist/)
[General]
FileSystem=media
FileSystem=media/materials/textures
"@
Write-Host "  $resourcesCfg"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  BUILD COMPLETE" -ForegroundColor Green
Write-Host "  Executable : $spacescapeExe" -ForegroundColor Green
Write-Host "  Output dir : $InstallDir" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
