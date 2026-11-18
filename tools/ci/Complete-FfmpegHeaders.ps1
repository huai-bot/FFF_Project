# Complete generated public headers omitted by the source-only preparation script.
# The two files come from the same SHA256-pinned Windows x64 runtime archive;
# never overwrite source API/structure/version headers with another commit's headers.
[CmdletBinding()]
param(
    [string]$ProjectRoot = ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))),
    [string]$ArchivePath = ''
)
$ErrorActionPreference = 'Stop'
$url = 'https://github.com/FFmpeg-Builds/FFmpeg-Builds/releases/download/autobuild-2026-11-17-12-40/ffmpeg-N-129000-g64f6bcffaf-win64-lgpl-shared.zip'
$archiveHash = 'd188c32646e6e588e1bef25adaa3b723f11513ffce475ace1823197cb1b6857b'
$generated = @(
    @{ Name = 'avconfig.h'; Sha256 = '975611AD5EBA15212D9E1D5FCA9D4FDF0DAEC6D2269B2FCAB8E29AF8667164BC' },
    @{ Name = 'ffversion.h'; Sha256 = '87E76B9E2BE48879B2845CD69553521B3D55EC149EF338ECB203570A72575E0E' }
)
$destination = Join-Path $ProjectRoot 'third_party\ffmpeg\include\libavutil'
if (-not (Test-Path -LiteralPath (Join-Path $destination 'avutil.h') -PathType Leaf)) {
    throw 'Prepare pinned source headers before completing generated headers.'
}
$missing = @($generated | Where-Object {
    $path = Join-Path $destination $_.Name
    -not (Test-Path -LiteralPath $path -PathType Leaf) -or
    (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $_.Sha256
})
if ($missing.Count) {
    $tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
    $work = Join-Path $tempRoot ('fff-generated-headers-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    if (-not $ArchivePath) {
        $ArchivePath = Join-Path $work 'ffmpeg-lgpl.zip'
        Invoke-WebRequest -Uri $url -OutFile $ArchivePath
    }
    if ((Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash -ne $archiveHash) {
        throw 'Generated-header archive SHA256 mismatch.'
    }
    $extract = Join-Path $work 'archive'
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $extract
    foreach ($item in $generated) {
        $sources = @(Get-ChildItem -LiteralPath $extract -Recurse -File -Filter $item.Name |
            Where-Object { $_.FullName -match '[\\/]include[\\/]libavutil[\\/]' })
        if ($sources.Count -ne 1) { throw "Expected one generated public header: $($item.Name)" }
        if ((Get-FileHash -LiteralPath $sources[0].FullName -Algorithm SHA256).Hash -ne $item.Sha256) {
            throw "Generated public header SHA256 mismatch: $($item.Name)"
        }
        Copy-Item -LiteralPath $sources[0].FullName -Destination (Join-Path $destination $item.Name) -Force
    }
}
foreach ($item in $generated) {
    if ((Get-FileHash -LiteralPath (Join-Path $destination $item.Name) -Algorithm SHA256).Hash -ne $item.Sha256) {
        throw "Prepared generated header SHA256 mismatch: $($item.Name)"
    }
}
Write-Host 'Verified generated Windows x64 FFmpeg public headers: avconfig.h and ffversion.h.'
Write-Host 'Source API/version headers remain pinned separately; ffversion.h describes the runtime binary, not the source commit.'
