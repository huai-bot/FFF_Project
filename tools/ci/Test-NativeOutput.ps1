# Check the actual deployment folder, without requiring a GPU or desktop session.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class FffOutputProbe {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern IntPtr LoadLibraryExW(string name, IntPtr reserved, uint flags);
    [DllImport("kernel32.dll", CharSet=CharSet.Ansi, SetLastError=true)]
    private static extern IntPtr GetProcAddress(IntPtr handle, string name);
    [DllImport("kernel32.dll")] private static extern bool FreeLibrary(IntPtr handle);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate uint UIntFn();
    public static uint Check(string path, string versionExport) {
        // Resolve imports from this deployment directory, not the source cache.
        IntPtr h = LoadLibraryExW(path, IntPtr.Zero, 0x00000100 | 0x00001000);
        if (h == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot load " + path);
        try {
            if (String.IsNullOrEmpty(versionExport)) return 0;
            IntPtr p = GetProcAddress(h, versionExport);
            if (p == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Missing export " + versionExport);
            return Marshal.GetDelegateForFunctionPointer<UIntFn>(p)();
        } finally { FreeLibrary(h); }
    }
}
'@

$versions = @(
    @{ Name='avcodec-63.dll'; Export='avcodec_version'; Major=63 },
    @{ Name='avformat-63.dll'; Export='avformat_version'; Major=63 },
    @{ Name='avutil-61.dll'; Export='avutil_version'; Major=61 },
    @{ Name='swresample-7.dll'; Export='swresample_version'; Major=7 },
    @{ Name='swscale-10.dll'; Export='swscale_version'; Major=10 },
    @{ Name='avfilter-12.dll'; Export='avfilter_version'; Major=12 },
    @{ Name='FFF.Native.dll'; Export='FFF3FP_GetApiVersion'; Api=20 },
    @{ Name='libraw.dll'; Export='libraw_capabilities'; X3F=$true },
    @{ Name='ass-9.dll'; Export='' },
    @{ Name='bluray-3.dll'; Export='' }
)
foreach ($spec in $versions) {
    $path = Join-Path $OutputDirectory $spec.Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing deployed native DLL: $path" }
    $value = [FffOutputProbe]::Check($path, $spec.Export)
    if ($spec.ContainsKey('Major') -and ($value -shr 16) -ne $spec.Major) {
        throw "Unexpected FFmpeg major in $($spec.Name): $value"
    }
    if ($spec.ContainsKey('Api') -and $value -ne $spec.Api) {
        throw "Native player API mismatch: $value"
    }
    if ($spec.ContainsKey('X3F') -and ($value -band 16) -eq 0) {
        throw 'Deployed LibRaw lacks X3F support'
    }
    Write-Host "PASS deployed $($spec.Name): $value"
}
Write-Host 'Deployment native-load checks passed. This does not test hardware GPU rendering.'
