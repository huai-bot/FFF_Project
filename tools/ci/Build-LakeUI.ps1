# Build the public LakeUI source for FFF.Player on windows-2025-vs2026 + .NET 11.
# Pinned source: https://github.com/Lake1059/LakeUI/tree/dbff827669c69a273c571085fef3672e7c21ea83
# LakeUI 5.301 uses GPL-3.0-only; GPL section 2 permits private, non-conveyed use.
# Public distribution must be assessed separately against LICENSE.txt and README.md.
# This script only prepares local dependencies; it does not upload build artifacts.
[CmdletBinding()]
param(
    [Alias('Commit')]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$LakeUICommit = 'dbff827669c69a273c571085fef3672e7c21ea83',

    [ValidateSet('net11.0-windows10.0.17763.0')]
    [string]$LakeUITfm = 'net11.0-windows10.0.17763.0',

    [ValidateSet('win-x64')]
    [string]$RuntimeIdentifier = 'win-x64'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Check every native exit code ourselves, including on GitHub's PowerShell 7 shell.
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Invoke-CheckedNative {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$Operation
    )
    & $FilePath @ArgumentList
    $nativeExitCode = $LASTEXITCODE
    if ($nativeExitCode -ne 0) {
        # Do not include environment variables or full command lines in errors.
        throw "$Operation failed (exit code $nativeExitCode)."
    }
}

$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$workspaceRoot = Split-Path -Parent $projectRoot
$lakeUIRoot = Join-Path $workspaceRoot 'LakeUI'
$playerProject = Join-Path $projectRoot 'FFF.Player\FFF.Player.vbproj'
$lakeUIProject = Join-Path $lakeUIRoot 'LakeUI\LakeUI.vbproj'
$referenceDirectory = Join-Path $lakeUIRoot "LakeUI\bin\Release\$LakeUITfm"
$publishDirectory = Join-Path $lakeUIRoot "LakeUI\bin\Release\$LakeUITfm\$RuntimeIdentifier\publish"

if (-not (Test-Path -LiteralPath $playerProject -PathType Leaf)) {
    throw 'FFF.Player.vbproj was not found relative to this script.'
}
$git = (Get-Command git -CommandType Application -ErrorAction Stop).Source
$dotnet = (Get-Command dotnet -CommandType Application -ErrorAction Stop).Source
$previousGitPrompt = $env:GIT_TERMINAL_PROMPT
$env:GIT_TERMINAL_PROMPT = '0'

try {
    if (-not (Test-Path -LiteralPath $lakeUIRoot)) {
        Invoke-CheckedNative -FilePath $git -ArgumentList @(
            'clone', '--depth', '1', 'https://github.com/Lake1059/LakeUI.git', $lakeUIRoot
        ) -Operation 'Clone public LakeUI source'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $lakeUIRoot '.git'))) {
        throw 'The adjacent LakeUI directory exists but is not a Git checkout.'
    }
    $checkoutRoot = (Invoke-CheckedNative -FilePath $git -ArgumentList @(
        '-C', $lakeUIRoot, 'rev-parse', '--show-toplevel'
    ) -Operation 'Check LakeUI checkout root' | Out-String).Trim()
    if ([IO.Path]::GetFullPath($checkoutRoot) -ne [IO.Path]::GetFullPath($lakeUIRoot)) {
        throw 'The adjacent LakeUI directory is not the root of its own checkout.'
    }
    $dirtyFiles = @(Invoke-CheckedNative -FilePath $git -ArgumentList @(
        '-C', $lakeUIRoot, 'status', '--porcelain', '--untracked-files=no'
    ) -Operation 'Check LakeUI source changes')
    if ($dirtyFiles.Count -ne 0) {
        throw 'LakeUI contains modified tracked files; refusing to replace local source.'
    }
    Invoke-CheckedNative -FilePath $git -ArgumentList @(
        '-C', $lakeUIRoot, 'fetch', '--depth', '1', '--no-tags',
        'https://github.com/Lake1059/LakeUI.git', $LakeUICommit
    ) -Operation 'Fetch pinned LakeUI commit'
    Invoke-CheckedNative -FilePath $git -ArgumentList @(
        '-C', $lakeUIRoot, 'checkout', '--detach', $LakeUICommit
    ) -Operation 'Check out pinned LakeUI commit'
    $actualCommit = (Invoke-CheckedNative -FilePath $git -ArgumentList @(
        '-C', $lakeUIRoot, 'rev-parse', 'HEAD'
    ) -Operation 'Verify LakeUI commit' | Out-String).Trim()
    if ($actualCommit -ne $LakeUICommit) {
        throw 'The checked-out LakeUI commit does not match the requested pin.'
    }
    if (-not (Test-Path -LiteralPath $lakeUIProject -PathType Leaf)) {
        throw 'LakeUI.vbproj is missing from the pinned source.'
    }
    $lakeProjectXml = [xml](Get-Content -LiteralPath $lakeUIProject -Raw -Encoding UTF8)
    $sourceTfm = [string]$lakeProjectXml.Project.PropertyGroup[0].TargetFramework
    if ($sourceTfm -ne $LakeUITfm) {
        throw "Pinned LakeUI source targets '$sourceTfm', not '$LakeUITfm'."
    }

    Push-Location -LiteralPath $lakeUIRoot
    try {
        # Resolve the SDK inside LakeUI so its committed global.json is respected.
        $sdkVersion = (Invoke-CheckedNative -FilePath $dotnet -ArgumentList @(
            '--version'
        ) -Operation 'Resolve .NET SDK' | Out-String).Trim()
        if ($sdkVersion -notmatch '^11\.0\.\d+$') {
            throw "A stable .NET 11 SDK is required; selected SDK is '$sdkVersion'."
        }
        Write-Host "LakeUI commit: $actualCommit; SDK: $sdkVersion; TFM: $LakeUITfm"
        Invoke-CheckedNative -FilePath $dotnet -ArgumentList @(
            'publish', $lakeUIProject, '-c', 'Release', '-f', $LakeUITfm,
            '-r', $RuntimeIdentifier, '--self-contained', 'false',
            '-p:PublishReadyToRun=true', '-p:GeneratePackageOnBuild=false',
            '-o', $publishDirectory, '--nologo'
        ) -Operation 'Publish LakeUI Release ReadyToRun'
    }
    finally {
        Pop-Location
    }

    $publishedAssembly = Join-Path $publishDirectory 'LakeUI.dll'
    if (-not (Test-Path -LiteralPath $publishedAssembly -PathType Leaf)) {
        throw 'LakeUI publish succeeded without producing LakeUI.dll.'
    }
    # Do not accept an IL-only assembly as a successful ReadyToRun publish.
    Add-Type -AssemblyName System.Reflection.Metadata
    $assemblyStream = [IO.File]::OpenRead($publishedAssembly)
    $peReader = $null
    try {
        $peReader = [System.Reflection.PortableExecutable.PEReader]::new($assemblyStream)
        $nativeHeader = $peReader.PEHeaders.CorHeader.ManagedNativeHeaderDirectory
        if ($nativeHeader.Size -lt 4 -or $nativeHeader.RelativeVirtualAddress -eq 0) {
            throw 'Published LakeUI.dll has no ReadyToRun native header.'
        }
        $signature = $peReader.GetSectionData($nativeHeader.RelativeVirtualAddress).GetContent(0, 4)
        if ($signature[0] -ne 0x52 -or $signature[1] -ne 0x54 -or
            $signature[2] -ne 0x52 -or $signature[3] -ne 0x00) {
            throw 'Published LakeUI.dll has an invalid ReadyToRun signature.'
        }
    }
    finally {
        if ($null -ne $peReader) { $peReader.Dispose() }
        $assemblyStream.Dispose()
    }
    # The player HintPath does not include the RID or publish subdirectory.
    # Copy the entire framework-dependent publish output, including SDK projections,
    # rather than leaving the IL-only build assembly at that HintPath.
    New-Item -ItemType Directory -Path $referenceDirectory -Force | Out-Null
    Get-ChildItem -LiteralPath $publishDirectory -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $referenceDirectory -Recurse -Force
    }
    Write-Host "LakeUI Release ReadyToRun is ready: $(Join-Path $referenceDirectory 'LakeUI.dll')"
}
finally {
    $env:GIT_TERMINAL_PROMPT = $previousGitPrompt
}
