# Windows TCP cache regression tests

The tests run against the MSVC build used by the Windows CI workflow. Install
Visual Studio C++ tools and WinDivert 2.2.2-A, then run from the repository root:

```powershell
Push-Location Windows
.\compile.ps1 -Compiler msvc -NoSign
Pop-Location
.\Windows\tests\run-msvc.ps1
```

The test runner accepts `-WinDivertPath` and `-BuildPath` overrides. It requires
all five runtime artifacts (GUI, CLI, core DLL, WinDivert DLL and driver), fails
on any test/build failure, and writes compiler/test logs under
`Windows/output/test-logs`. The Windows Actions workflow runs it for PRs to
`main`, `dev` and `master`, and uploads artifacts and logs even on failure.

## Coverage

`port_cache_test.c` runs the production packet loop against synthetic IPv4/IPv6
TCP packets. Receive/send and rule decisions are mocked; parsing, packet
rewriting, connection tracking and the IPv4 PID cache use production code.
Neither this test nor `dll_load_test.c` opens the WinDivert driver.

Cases include stale DIRECT -> PROXY and BLOCK on a fresh SYN, PID eviction,
cross-family port reuse, SYN retransmissions, established proxied traffic,
DIRECT fast-path preservation, SYN+ACK, and FIN/RST cache retirement.
The DLL smoke test uses the GUI's loader, resolves all its required exports,
and adds/disables/enables/deletes an in-memory rule. CLI help/version are
checked separately. A passing run does not start interception or change any
installed ProxyBridge configuration.

## Scope and live validation

These tests reproduce the decision-cache defect deterministically. They do
not replace a real driver/network test or a multi-hour soak test. The existing
port-based connection keys, UDP behavior and rule-edit invalidation are
outside this fix.

For live testing, export a profile from the installed GUI, fully exit that
instance, then launch the separately built CLI as administrator:

```powershell
.\ProxyBridge_CLI.exe --profile 'C:\path\test.pbprofile' --verbose 3 2>&1 |
    Tee-Object -FilePath .\soak-test.log
```

Do not run two instances at once. Exercise repeated new connections and idle
periods; check that matching flows continue to use PROXY. Stop with Ctrl+C and
reopen the installed application to roll back. The GUI shares its settings
under `%APPDATA%\ProxyBridge`; back up that folder before testing the GUI.
