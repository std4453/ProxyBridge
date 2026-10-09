param(
    [string]$WinDivertPath = 'C:\WinDivert-2.2.2-A',
    [string]$BuildPath = (Join-Path $PSScriptRoot '../output')
)

$ErrorActionPreference = 'Stop'
$WinDivertPath = (Resolve-Path -LiteralPath $WinDivertPath).Path
$BuildPath = (Resolve-Path -LiteralPath $BuildPath).Path
$sourcePath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../src')).Path

# compile.ps1 can report a GUI/CLI failure without failing the whole script.
# Require every runtime artifact before running the tests.
foreach ($file in @('ProxyBridgeCore.dll', 'ProxyBridge.exe', 'ProxyBridge_CLI.exe', 'WinDivert.dll', 'WinDivert64.sys')) {
    if (-not (Test-Path -LiteralPath (Join-Path $BuildPath $file))) {
        throw "Build artifact missing: $file"
    }
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vsPath = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsPath) { throw 'MSVC x64 tools not found' }
$vcvars = Join-Path $vsPath 'VC/Auxiliary/Build/vcvarsall.bat'
$environment = & $env:ComSpec /d /s /c "`"`"$vcvars`" x64 >nul && set`""
if ($LASTEXITCODE -ne 0) { throw 'Could not initialize MSVC environment' }
foreach ($line in $environment) {
    if ($line -match '^([^=]+)=(.*)$') {
        [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
    }
}

$logs = Join-Path $BuildPath 'test-logs'
New-Item -ItemType Directory -Path $logs -Force | Out-Null
function Invoke-TestStep {
    param([string]$Name, [string]$Tool, [string[]]$Arguments)
    & $Tool @Arguments *> (Join-Path $logs "$Name.log")
    $result = $LASTEXITCODE
    Get-Content -LiteralPath (Join-Path $logs "$Name.log")
    if ($result -ne 0) { throw "$Name failed (exit $result)" }
}

$flags = @('/nologo', '/O2', '/W4', '/utf-8', '/D_WIN32_WINNT=0x0601',
    '/D_CRT_SECURE_NO_WARNINGS', '/D_WINSOCK_DEPRECATED_NO_WARNINGS',
    '/DPROXYBRIDGE_EXPORTS', "/I$sourcePath", "/I$WinDivertPath/include")
$sources = @(Get-ChildItem -LiteralPath $sourcePath -Filter '*.c' |
    Where-Object Name -ne 'ProxyBridge.c' | ForEach-Object FullName)
Push-Location $logs
try {
    # The harness includes ProxyBridge.c and substitutes only packet I/O and
    # rule verdicts. All other core translation units are linked normally.
    Invoke-TestStep 'packet-build' 'cl.exe' ($flags + @("$PSScriptRoot/port_cache_test.c") + $sources +
        @("/Fe:$BuildPath/port_cache_test.exe", '/link', "/LIBPATH:$WinDivertPath/x64", 'WinDivert.lib', 'ws2_32.lib', 'iphlpapi.lib'))
    Invoke-TestStep 'packet-run' "$BuildPath/port_cache_test.exe" @()
    Invoke-TestStep 'dll-build' 'cl.exe' @('/nologo', '/O2', '/W4', '/utf-8',
        "$PSScriptRoot/dll_load_test.c", "/Fe:$BuildPath/dll_load_test.exe")
    Invoke-TestStep 'dll-run' "$BuildPath/dll_load_test.exe" @()
    Invoke-TestStep 'cli-version' "$BuildPath/ProxyBridge_CLI.exe" @('--version')
    Invoke-TestStep 'cli-help' "$BuildPath/ProxyBridge_CLI.exe" @('--help')
} finally { Pop-Location }
