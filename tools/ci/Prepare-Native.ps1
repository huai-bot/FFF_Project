# Prepare the original player's x64 native dependencies on windows-2025-vs2026.
# Run with PowerShell 7: ./tools/ci/Prepare-Native.ps1 -Parallel 2
# Sources/build trees live in RUNNER_TEMP, never in the prepared dependency cache.
[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Release',
    [ValidateRange(1, 64)][int]$Parallel = 2,
    [string]$WorkDirectory = '',
    [switch]$SkipIamf
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'Use PowerShell 7 (pwsh) to prepare native dependencies.' }
$ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$Tools = Join-Path $ProjectRoot 'tools'
. (Join-Path $Tools 'Resolve-Toolchain.ps1')
. (Join-Path $Tools 'Resolve-NativeDependencies.ps1')

$FfmpegHeadersCommit = '7f6b35d6c804ed8d1bc517c33044f075d72852ba'
$FfmpegUrl = 'https://github.com/FFmpeg-Builds/FFmpeg-Builds/releases/download/autobuild-2026-11-17-12-40/ffmpeg-N-129000-g64f6bcffaf-win64-lgpl-shared.zip'
$FfmpegSha256 = 'd188c32646e6e588e1bef25adaa3b723f11513ffce475ace1823197cb1b6857b'
$LibRawCommit = 'cf02d66eb5c19d4e46df7aee0582e47a4918509a' # 0.22.3
$LibRawCmakeCommit = 'eb98e4325aef2ce85d2eb031c2ff18640ca616d3'
$LibiamfCommit = 'b276f4371a8ae4f370a656e914f7b07e4cd5a2fa'
$VcpkgBaseline = 'e03dc9b29710050cd1018bc5674688108658d327'
$ScriptHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
$Pwsh = (Get-Process -Id $PID).Path

function Invoke-Checked {
    param([string]$Executable, [string[]]$Arguments)
    & $Executable @Arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        # vcpkg's top-level output names detailed logs but does not print them.
        if ([IO.Path]::GetFileName($Executable) -eq 'vcpkg.exe') {
            $detectRoot = Join-Path (Split-Path -Parent $Executable) 'buildtrees\detect_compiler'
            if (Test-Path -LiteralPath $detectRoot) {
                foreach ($log in Get-ChildItem -LiteralPath $detectRoot -File -Filter '*fff-x64-static-md*.log') {
                    Write-Host "Compiler diagnostic: $($log.FullName)"
                    Get-Content -LiteralPath $log.FullName -Tail 100 | Write-Host
                }
            }
        }
        throw "Command failed (exit $exitCode): $Executable $($Arguments -join ' ')"
    }
}
function Invoke-Preparation {
    param([string]$Name, [string[]]$Arguments = @())
    # A child process catches explicit exit as well as native nonzero exit codes.
    Invoke-Checked $Pwsh (@('-NoLogo', '-NoProfile', '-File', (Join-Path $Tools $Name)) + $Arguments)
}
function Get-PinnedRepository {
    param([string]$Url, [string]$Commit, [string]$Directory)
    if (-not (Test-Path -LiteralPath (Join-Path $Directory '.git'))) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
        Invoke-Checked $Git @('init', $Directory)
        Invoke-Checked $Git @('-C', $Directory, 'remote', 'add', 'origin', $Url)
    }
    Invoke-Checked $Git @('-C', $Directory, 'fetch', '--depth', '1', 'origin', $Commit)
    Invoke-Checked $Git @('-C', $Directory, 'checkout', '--detach', 'FETCH_HEAD')
    $head = & $Git -C $Directory rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $head.Trim() -ne $Commit) { throw "Incorrect source revision in $Directory" }
}
function Test-Prepared {
    param([string]$Root, [string]$Key, [string[]]$Files)
    $marker = Join-Path $Root '.ci-ready.json'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { return $false }
    $record = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
    if ($record.key -ne $Key) { return $false }
    foreach ($relative in $Files) {
        $file = Join-Path $Root $relative
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $false }
        if ((Get-Item -LiteralPath $file).Length -eq 0) { return $false }
    }
    foreach ($item in $record.checked) {
        $path = Join-Path $Root $item.path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $item.sha256) { return $false }
    }
    return $true
}
function Save-Prepared {
    param([string]$Root, [string]$Key, [string[]]$CheckedFiles)
    $checked = foreach ($relative in $CheckedFiles) {
        $path = Join-Path $Root $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing prepared file: $path" }
        @{ path = $relative; sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }
    }
    @{ key = $Key; checked = @($checked) } | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath (Join-Path $Root '.ci-ready.json') -Encoding utf8
}
function Copy-Licenses {
    param([string]$Source, [string]$Destination)
    foreach ($file in Get-ChildItem -LiteralPath $Source -Recurse -File |
        Where-Object { $_.Name -match '^(LICENSE|COPYING|COPYRIGHT|NOTICE)([._-]|$)' -and $_.FullName -notmatch '[\\/]\.git[\\/]' }) {
        $relative = [IO.Path]::GetRelativePath($Source, $file.FullName)
        $target = Join-Path $Destination $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
}

# setup-msbuild only adds MSBuild to PATH; lib.exe/dumpbin.exe also require VS.
$Vs = Get-VisualStudioInstallation
$devModule = Join-Path $Vs 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll'
Import-Module -Name $devModule
Enter-VsDevShell -VsInstallPath $Vs -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
$env:CMAKE_GENERATOR = 'Visual Studio 18 2026'
$env:CMAKE_GENERATOR_TOOLSET = 'v145'
$env:VCPKG_MAX_CONCURRENCY = [string]$Parallel
$Git = Get-GitTool
$Cmake = Get-CMakeTool
$Vcpkg = Get-VcpkgTool
$env:VCPKG_EXE_PATH = $Vcpkg
$env:CMAKE_EXE_PATH = $Cmake
$env:GIT_EXE_PATH = $Git
$env:LIB_EXE_PATH = Get-VisualCppTool -Name 'lib.exe'
$env:DUMPBIN_EXE_PATH = Get-VisualCppTool -Name 'dumpbin.exe'
if (-not (Test-Path -LiteralPath (Join-Path $Vs 'MSBuild\Microsoft\VC\v180\Platforms\x64\PlatformToolsets\v145\Toolset.props'))) {
    throw 'Visual Studio 2026 with the v145 x64 toolset is required.'
}
$manifest = Get-Content -LiteralPath (Join-Path $ProjectRoot 'vcpkg.json') -Raw | ConvertFrom-Json
if ($manifest.'builtin-baseline' -ne $VcpkgBaseline) { throw 'The project vcpkg baseline changed; review the CI dependency pins.' }
if ([string]::IsNullOrWhiteSpace($WorkDirectory)) {
    $tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
    $WorkDirectory = Join-Path $tempRoot ('fff-native-ci-' + [guid]::NewGuid().ToString('N'))
}
$WorkDirectory = [IO.Path]::GetFullPath($WorkDirectory)
New-Item -ItemType Directory -Path $WorkDirectory -Force | Out-Null
Write-Host "Native build workspace: $WorkDirectory"

# Verify actual loaded versions, not filenames renamed by an import-lib generator.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FffCiNativeProbe {
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate uint UIntFn();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate IntPtr TextFn();
    public static uint UInt(string dll, string symbol) {
        IntPtr h = NativeLibrary.Load(dll);
        try { return Marshal.GetDelegateForFunctionPointer<UIntFn>(NativeLibrary.GetExport(h, symbol))(); }
        finally { NativeLibrary.Free(h); }
    }
    public static string Text(string dll, string symbol) {
        IntPtr h = NativeLibrary.Load(dll);
        try { return Marshal.PtrToStringAnsi(Marshal.GetDelegateForFunctionPointer<TextFn>(NativeLibrary.GetExport(h, symbol))()); }
        finally { NativeLibrary.Free(h); }
    }
}
'@
$FfmpegSpecs = @(
    @{ Name = 'avcodec'; Major = 63; Minor = 28; Micro = 100 },
    @{ Name = 'avformat'; Major = 63; Minor = 20; Micro = 101 },
    @{ Name = 'avutil'; Major = 61; Minor = 21; Micro = 100 },
    @{ Name = 'swresample'; Major = 7; Minor = 7; Micro = 100 },
    @{ Name = 'swscale'; Major = 10; Minor = 6; Micro = 100 },
    @{ Name = 'avfilter'; Major = 12; Minor = 12; Micro = 100 }
)
function Assert-FfmpegRuntime {
    param([string]$Directory)
    foreach ($spec in $FfmpegSpecs) {
        $dll = Join-Path $Directory "$($spec.Name)-$($spec.Major).dll"
        $actual = [FffCiNativeProbe]::UInt($dll, "$($spec.Name)_version")
        $expected = ($spec.Major -shl 16) -bor ($spec.Minor -shl 8) -bor $spec.Micro
        if ($actual -ne $expected) { throw "Unexpected FFmpeg version in $dll (got $actual, expected $expected)." }
    }
    $config = [FffCiNativeProbe]::Text((Join-Path $Directory 'avutil-61.dll'), 'avutil_configuration')
    if ($config -match '--enable-(gpl|nonfree|libfdk-aac|libx264|libx265)(\s|$)') { throw 'Expected the pinned LGPL FFmpeg variant, not GPL/nonfree.' }
    if ($config -notmatch '--enable-libplacebo(\s|$)') { throw 'The pinned FFmpeg libplacebo capability is missing.' }
}

$FfmpegRoot = Join-Path $ProjectRoot 'third_party\ffmpeg'
$Runtime = Join-Path $ProjectRoot 'runtime'
$ffmpegFiles = @('COPYING.LGPLv2.1', 'COPYING.LGPLv3', 'LICENSE.FFmpeg-binary.txt')
foreach ($spec in $FfmpegSpecs) {
    $ffmpegFiles += "include\lib$($spec.Name)\$($spec.Name).h"
    $ffmpegFiles += "lib\x64\$($spec.Name)-$($spec.Major).lib"
}
$ffmpegKey = "$ScriptHash|$FfmpegHeadersCommit|$FfmpegSha256"
$runtimePresent = @(Get-MissingDependencyFiles -Root $Runtime -RelativePaths @($FfmpegSpecs | ForEach-Object { "$($_.Name)-$($_.Major).dll" })).Count -eq 0
if ((Test-Prepared $FfmpegRoot $ffmpegKey $ffmpegFiles) -and $runtimePresent) {
    Assert-FfmpegRuntime $Runtime
    Write-Host 'Verified pinned FFmpeg cache.'
} else {
    $archive = Join-Path $WorkDirectory 'ffmpeg-lgpl.zip'
    Invoke-WebRequest -Uri $FfmpegUrl -OutFile $archive
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $FfmpegSha256) { throw 'FFmpeg archive SHA256 mismatch.' }
    $extract = Join-Path $WorkDirectory 'ffmpeg-lgpl'
    Expand-Archive -LiteralPath $archive -DestinationPath $extract -Force
    $bins = @(Get-ChildItem -LiteralPath $extract -Recurse -File -Filter ffmpeg.exe)
    if ($bins.Count -ne 1) { throw 'Expected one ffmpeg.exe in the pinned archive.' }
    $bin = $bins[0].DirectoryName
    Assert-FfmpegRuntime $bin
    $source = Join-Path $WorkDirectory 'ffmpeg-source'
    # Shallow fetch avoids the existing preparation script's full repository clone.
    Get-PinnedRepository 'https://github.com/FFmpeg/FFmpeg.git' $FfmpegHeadersCommit $source
    Invoke-Preparation '准备FFmpeg.ps1' @('-RuntimeSource', $bin, '-SourceDirectory', $source)
    # Keep all DLLs, including the binary package's transitive runtime dependencies.
    Get-ChildItem -LiteralPath $bin -File -Filter *.dll | Copy-Item -Destination $Runtime -Force
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $bin) 'LICENSE.txt') -Destination (Join-Path $FfmpegRoot 'LICENSE.FFmpeg-binary.txt') -Force
    Copy-Item -LiteralPath (Join-Path $source 'COPYING.GPLv3') -Destination $FfmpegRoot -Force
    @("headers=$FfmpegHeadersCommit", "binary=$FfmpegUrl", "sha256=$FfmpegSha256", 'variant=LGPLv3 shared; no x264/x265/fdk-aac; libplacebo retained') |
        Set-Content -LiteralPath (Join-Path $FfmpegRoot 'CI-SOURCES.txt') -Encoding utf8
    Assert-FfmpegRuntime $Runtime
    Save-Prepared $FfmpegRoot $ffmpegKey $ffmpegFiles
}
Write-Warning 'This CI uses LGPL FFmpeg: x264/x265 and FDK-AAC are absent; libplacebo is retained. The author nonfree binary must not be publicly redistributed.'

# Reuse the existing pinned vcpkg manifest for subtitles and disc navigation.
$vcpkgRoot = Join-Path $ProjectRoot 'third_party\vcpkg_installed\x64-windows'
$discKey = "$ScriptHash|$VcpkgBaseline|v145|$Configuration"
$discFiles = @('include\ass\ass.h', 'include\libbluray\bluray.h', 'include\udfread\udfread.h', 'share\libass\copyright', 'share\libbluray\copyright')
if (-not (Test-Prepared $vcpkgRoot $discKey $discFiles)) {
    Invoke-Preparation '准备光盘库.ps1'
    Initialize-NativeDependencies -ProjectRoot $ProjectRoot -Configuration $Configuration -SkipPreparation -SkipIamf
    Save-Prepared $vcpkgRoot $discKey $discFiles
} else {
    Initialize-NativeDependencies -ProjectRoot $ProjectRoot -Configuration $Configuration -SkipPreparation -SkipIamf
    Write-Host 'Verified subtitle/disc dependency cache.'
}

# LibRaw's official CMake support lives in a separate repository. The wrapper only
# sets the DLL/import-library basename expected by FFF.Native; it changes no source.
$RawRoot = Join-Path $ProjectRoot 'third_party\libraw'
$rawKey = "$ScriptHash|$LibRawCommit|$LibRawCmakeCommit|$VcpkgBaseline|v145|$Configuration|X3F|jpeg8|lcms|zlib"
$rawFiles = @('include\libraw\libraw.h', 'include\libraw\libraw_const.h', 'include\libraw\libraw_types.h', 'include\libraw\libraw_version.h', 'lib\x64\libraw.lib', 'bin\x64\libraw.dll', 'LICENSE.LGPL', 'LICENSE.CDDL', 'COPYRIGHT', 'LICENSE.LibRaw-cmake.txt')
if (-not (Test-Prepared $RawRoot $rawKey $rawFiles)) {
    $rawSource = Join-Path $WorkDirectory 'libraw-source'
    $rawCmake = Join-Path $WorkDirectory 'libraw-cmake'
    Get-PinnedRepository 'https://github.com/LibRaw/LibRaw.git' $LibRawCommit $rawSource
    Get-PinnedRepository 'https://github.com/LibRaw/LibRaw-cmake.git' $LibRawCmakeCommit $rawCmake
    $depsManifest = Join-Path $WorkDirectory 'libraw-deps'
    $triplets = Join-Path $depsManifest 'triplets'
    New-Item -ItemType Directory -Path $triplets -Force | Out-Null
    @{ name = 'fff-libraw-ci'; 'version-string' = '1'; 'builtin-baseline' = $VcpkgBaseline;
        dependencies = @('zlib', @{name='libjpeg-turbo'; features=@('jpeg8')}, @{name='lcms'; 'default-features'=$false}) } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $depsManifest 'vcpkg.json') -Encoding utf8
    # Desktop Windows uses an unset CMAKE_SYSTEM_NAME in vcpkg. The explicit
    # value "Windows" is not a supported triplet system and loses Windows flags.
    @('set(VCPKG_TARGET_ARCHITECTURE x64)', 'set(VCPKG_CRT_LINKAGE dynamic)', 'set(VCPKG_LIBRARY_LINKAGE static)', 'set(VCPKG_PLATFORM_TOOLSET v145)', 'set(VCPKG_BUILD_TYPE release)') |
        Set-Content -LiteralPath (Join-Path $triplets 'fff-x64-static-md.cmake') -Encoding ascii
    $depsRoot = Join-Path $WorkDirectory 'libraw-deps-installed'
    Invoke-Checked $Vcpkg @('install', '--triplet=fff-x64-static-md', "--overlay-triplets=$triplets", "--x-manifest-root=$depsManifest", "--x-install-root=$depsRoot")
    $deps = Join-Path $depsRoot 'fff-x64-static-md'
    $wrapper = Join-Path $WorkDirectory 'libraw-wrapper'
    New-Item -ItemType Directory -Path $wrapper -Force | Out-Null
    @'
cmake_minimum_required(VERSION 3.28)
project(fff_libraw_ci LANGUAGES CXX)
add_subdirectory("${FFF_LIBRAW_CMAKE}" upstream)
set_target_properties(raw_r PROPERTIES OUTPUT_NAME libraw DEBUG_POSTFIX "")
'@ | Set-Content -LiteralPath (Join-Path $wrapper 'CMakeLists.txt') -Encoding ascii
    $rawBuild = Join-Path $WorkDirectory 'libraw-build'
    Invoke-Checked $Cmake @('-S', $wrapper, '-B', $rawBuild, '-G', 'Visual Studio 18 2026', '-A', 'x64', '-T', 'v145',
        "-DFFF_LIBRAW_CMAKE=$rawCmake", "-DLIBRAW_PATH=$rawSource", "-DCMAKE_PREFIX_PATH=$deps",
        '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded$<$<CONFIG:Debug>:Debug>DLL', '-DCMAKE_POLICY_VERSION_MINIMUM=3.5',
        '-DBUILD_SHARED_LIBS=ON', '-DENABLE_EXAMPLES=OFF', '-DLIBRAW_INSTALL=OFF', '-DENABLE_X3FTOOLS=ON',
        '-DENABLE_OPENMP=OFF', '-DENABLE_RAWSPEED=OFF', '-DENABLE_JASPER=OFF', '-DENABLE_LCMS=ON',
        "-DLCMS2_INCLUDE_DIR=$deps\include", "-DLCMS2_LIBRARIES=$deps\lib\lcms2.lib",
        "-DZLIB_INCLUDE_DIR=$deps\include", "-DZLIB_LIBRARY=$deps\lib\zlib.lib",
        "-DJPEG_INCLUDE_DIR=$deps\include", "-DJPEG_LIBRARY=$deps\lib\jpeg.lib")
    Invoke-Checked $Cmake @('--build', $rawBuild, '--config', $Configuration, '--target', 'raw_r', '--parallel', [string]$Parallel)
    $rawBin = Join-Path $rawBuild "upstream\$Configuration"
    foreach ($directory in @('include\libraw', 'lib\x64', 'bin\x64')) { New-Item -ItemType Directory -Path (Join-Path $RawRoot $directory) -Force | Out-Null }
    Get-ChildItem -LiteralPath (Join-Path $rawSource 'libraw') -Filter *.h -File | Copy-Item -Destination (Join-Path $RawRoot 'include\libraw') -Force
    Copy-Item -LiteralPath (Join-Path $rawBuild 'upstream\libraw_config.h') -Destination (Join-Path $RawRoot 'include\libraw') -Force
    Copy-Item -LiteralPath (Join-Path $rawBin 'libraw.lib') -Destination (Join-Path $RawRoot 'lib\x64') -Force
    Copy-Item -LiteralPath (Join-Path $rawBin 'libraw.dll') -Destination (Join-Path $RawRoot 'bin\x64') -Force
    foreach ($name in @('LICENSE.LGPL', 'LICENSE.CDDL', 'COPYRIGHT')) { Copy-Item -LiteralPath (Join-Path $rawSource $name) -Destination $RawRoot -Force }
    Copy-Item -LiteralPath (Join-Path $rawCmake 'LICENSE') -Destination (Join-Path $RawRoot 'LICENSE.LibRaw-cmake.txt') -Force
    Copy-Licenses (Join-Path $deps 'share') (Join-Path $RawRoot 'licenses\compression')
    @("LibRaw=0.22.3 $LibRawCommit", "LibRaw-cmake=$LibRawCmakeCommit", "vcpkg-baseline=$VcpkgBaseline", 'shared raw_r, v145, dynamic CRT, X3F enabled, static zlib/jpeg8/lcms; OpenMP and optional RawSpeed disabled') |
        Set-Content -LiteralPath (Join-Path $RawRoot 'CI-SOURCES.txt') -Encoding utf8
    Save-Prepared $RawRoot $rawKey $rawFiles
}
$rawDll = Join-Path $RawRoot 'bin\x64\libraw.dll'
if ([FffCiNativeProbe]::Text($rawDll, 'libraw_version') -notmatch '^0\.22\.3(?:-Release)?$') { throw 'LibRaw DLL version mismatch.' }
if (([FffCiNativeProbe]::UInt($rawDll, 'libraw_capabilities') -band 16) -eq 0) { throw 'LibRaw was built without X3F support.' }
Write-Host 'Verified LibRaw 0.22.3 with X3F support.'

# Keep IAMF and OBR binaural rendering by default. The existing script pins the
# IAMF commit; that commit pins OAR, Opus 1.4, FLAC 1.4.2 and fdk-aac 716f4394...
if (-not $SkipIamf) {
    $iamfRoot = Join-Path $ProjectRoot 'third_party\libiamf'
    $iamfKey = "$ScriptHash|$LibiamfCommit|v145|$Configuration|binaural"
    $iamfFiles = @(Get-LibiamfRequiredFiles -ProjectRoot $ProjectRoot -Configuration $Configuration) + @('LICENSE.libiamf.txt', 'CI-SOURCES.txt')
    if (-not (Test-Prepared $iamfRoot $iamfKey $iamfFiles)) {
        $iamfRepo = Join-Path $WorkDirectory 'libiamf-source'
        Get-PinnedRepository 'https://github.com/AOMediaCodec/libiamf.git' $LibiamfCommit $iamfRepo
        $iamfBuild = Join-Path $WorkDirectory 'libiamf-build'
        # The parent's environment supplies VS2026/v145 even to nested CMake builds.
        Invoke-Preparation '准备Libiamf.ps1' @('-RepoPath', $iamfRepo, '-BuildDirectory', $iamfBuild, '-PinnedCommit', $LibiamfCommit, '-Configuration', $Configuration, '-Parallel', [string]$Parallel)
        Copy-Licenses $iamfRepo (Join-Path $iamfRoot 'licenses\source')
        Copy-Licenses $iamfBuild (Join-Path $iamfRoot 'licenses\build-dependencies')
        @("libiamf=$LibiamfCommit", 'Opus=1.4; FLAC=1.4.2; fdk-aac=716f4394641d53f0d79c9ddac3fa93b03a49f278', 'OAR and OBR/Abseil revisions follow the pinned recursive submodule tree; IAMF_ENABLE_BINAURALIZER=ON', 'FDK-AAC here belongs to libiamf, not the LGPL FFmpeg DLLs; no binary publishing is performed.') |
            Set-Content -LiteralPath (Join-Path $iamfRoot 'CI-SOURCES.txt') -Encoding utf8
        Save-Prepared $iamfRoot $iamfKey @('include\IAMF_decoder.h', 'LICENSE.libiamf.txt', 'CI-SOURCES.txt')
    }
    Assert-LibiamfReady -ProjectRoot $ProjectRoot -Configuration $Configuration
    Write-Host 'Verified IAMF and OBR binaural dependency files.'
} else { Write-Warning 'IAMF preparation was explicitly skipped; do not require FFF_FORCE_LIBIAMF=true in this build.' }

Initialize-NativeDependencies -ProjectRoot $ProjectRoot -Configuration $Configuration -SkipPreparation -SkipIamf:$SkipIamf
Write-Host "Native dependencies are ready for $Configuration x64 v145. Build with FFF_FORCE_LIBIAMF=true when IAMF was not skipped."
