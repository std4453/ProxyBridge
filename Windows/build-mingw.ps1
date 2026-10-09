param(
    [Parameter(Mandatory=$true)]
    [string]$WinDivertPath,
    [switch]$RunTests
)

# Separate unsigned x64 build. Never deletes an output directory, installs a
# driver, runs the GUI, or touches an installed ProxyBridge copy.
$ErrorActionPreference = 'Stop'
$WinDivertPath = (Resolve-Path -LiteralPath $WinDivertPath).Path
$gcc = (Get-Command gcc -ErrorAction Stop).Source
$windres = (Get-Command windres -ErrorAction Stop).Source
$target = & $gcc -dumpmachine
if ($LASTEXITCODE -ne 0 -or $target -notmatch '^x86_64-.*mingw32$') {
    throw "An x64 MinGW-w64 compiler is required; found: $target"
}
foreach ($file in @('include/windivert.h', 'x64/WinDivert.lib', 'x64/WinDivert.dll', 'x64/WinDivert64.sys')) {
    if (-not (Test-Path -LiteralPath (Join-Path $WinDivertPath $file))) {
        throw "Missing WinDivert dependency: $file"
    }
}
$outputRoot = Join-Path $PSScriptRoot 'output-mingw'
$buildName = 'issue206-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$buildDir = Join-Path $outputRoot $buildName
$logs = Join-Path $buildDir 'logs'
New-Item -ItemType Directory -Path $logs -Force | Out-Null

function Invoke-BuildStep {
    param([string]$Name, [string]$Tool, [string[]]$Arguments)
    Write-Host "Building $Name..."
    & $Tool @Arguments *> (Join-Path $logs "$Name.log")
    if ($LASTEXITCODE -ne 0) {
        Get-Content -LiteralPath (Join-Path $logs "$Name.log")
        throw "$Name failed (exit $LASTEXITCODE); see $logs"
    }
}

$common = @('-O2', '-Wall', '-Wno-unknown-pragmas', '-D_WIN32_WINNT=0x0601', '-static-libgcc')
$coreFlags = @('-DPROXYBRIDGE_EXPORTS', "-I$WinDivertPath/include", "-I$PSScriptRoot/src")
$coreLibs = @("-L$WinDivertPath/x64", '-lWinDivert', '-lws2_32', '-liphlpapi')
$sources = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'src') -Filter '*.c' | ForEach-Object FullName)
Invoke-BuildStep 'core' $gcc ($common + $coreFlags + @('-shared') + $sources + $coreLibs + @('-o', "$buildDir/ProxyBridgeCore.dll"))
Invoke-BuildStep 'cli' $gcc ($common + @("$PSScriptRoot/cli/main.c", '-lwinhttp', '-lshell32', '-ladvapi32', '-o', "$buildDir/ProxyBridge_CLI.exe"))
Push-Location (Join-Path $PSScriptRoot 'gui/res')
try {
    Invoke-BuildStep 'resources' $windres @('-i', 'app.rc', '-o', "$logs/app.o")
} finally { Pop-Location }
Invoke-BuildStep 'gui' $gcc ($common + @('-DUNICODE', '-D_UNICODE', '-municode', '-mwindows',
    "$PSScriptRoot/gui/main.c", "$PSScriptRoot/gui/profile/profile.c", "$logs/app.o",
    '-luser32', '-lgdi32', '-lcomctl32', '-lshell32', '-lcomdlg32', '-lwinhttp', '-ldwmapi', '-luxtheme',
    '-o', "$buildDir/ProxyBridge.exe"))
Copy-Item -LiteralPath "$WinDivertPath/x64/WinDivert.dll", "$WinDivertPath/x64/WinDivert64.sys" -Destination $buildDir
Copy-Item -LiteralPath "$WinDivertPath/LICENSE" -Destination "$buildDir/WinDivert-LICENSE.txt"
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../LICENSE') -Destination "$buildDir/ProxyBridge-LICENSE.txt"

if ($RunTests) {
    $testSources = @($sources | Where-Object { [IO.Path]::GetFileName($_) -ne 'ProxyBridge.c' })
    Invoke-BuildStep 'test-build' $gcc ($common + $coreFlags + @("$PSScriptRoot/tests/port_cache_test.c") + $testSources + $coreLibs + @('-o', "$buildDir/port_cache_test.exe"))
    Invoke-BuildStep 'test-run' "$buildDir/port_cache_test.exe" @()
    Get-Content -LiteralPath "$logs/test-run.log"
    Invoke-BuildStep 'dll-test-build' $gcc ($common + @("$PSScriptRoot/tests/dll_load_test.c", '-o', "$buildDir/dll_load_test.exe"))
    Invoke-BuildStep 'dll-test-run' "$buildDir/dll_load_test.exe" @()
    Get-Content -LiteralPath "$logs/dll-test-run.log"
}
Invoke-BuildStep 'cli-version' "$buildDir/ProxyBridge_CLI.exe" @('--version')
Invoke-BuildStep 'cli-help' "$buildDir/ProxyBridge_CLI.exe" @('--help')
Copy-Item -LiteralPath "$PSScriptRoot/tests/README.md" -Destination "$buildDir/TESTING.md"

$revision = git -C $PSScriptRoot rev-parse HEAD
$compilerVersion = & $gcc --version | Select-Object -First 1
@(
    'Unsigned local test build for issue #206 (not an official release).'
    "Base commit: $revision; local source modifications included."
    "Compiler: $compilerVersion"
    "Target: $target"
    "Built: $([DateTimeOffset]::Now.ToString('o'))"
    "Regression tests requested: $RunTests"
    'No installer is generated and no application or driver is started.'
) | Set-Content -LiteralPath "$buildDir/BUILD-INFO.txt" -Encoding utf8
Get-ChildItem -LiteralPath $buildDir -File | Where-Object Extension -in '.exe', '.dll', '.sys' |
    Get-FileHash -Algorithm SHA256 | ForEach-Object {
        "$($_.Hash)  $([IO.Path]::GetFileName($_.Path))"
    } | Set-Content -LiteralPath "$buildDir/SHA256SUMS.txt" -Encoding ascii
Write-Host "Build ready: $buildDir"
