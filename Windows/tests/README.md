# Windows issue #206 test build

This is an unsigned local build based on commit `02703a0` (4.0.13-Beta),
not a patched copy of the installed 4.0.0 binary or an official release.
The DLL, CLI and GUI are built together from the same sources.

## Rebuild

Use x64 MinGW-w64 GCC and windres on PATH. Download WinDivert 2.2.2-A from
https://github.com/basil00/WinDivert/releases/download/v2.2.2/WinDivert-2.2.2-A.zip
and verify its SHA256 against the repository's Windows CI value:

```text
63CB41763BB4B20F600B6DE04E991A9C2BE73279E317D4D82F237B150C5F3F15
```

From the repository root, with the archive extracted under `.local-build`:

```powershell
.\Windows\build-mingw.ps1 -WinDivertPath .\.local-build\WinDivert-2.2.2-A -RunTests
```

Each run creates a fresh directory under `Windows/output-mingw`. It does not
install anything, start interception, or delete previous builds. Logs, binary
hashes, compiler information and license files are included.

## Automated coverage

`port_cache_test.c` runs the production packet loop against synthetic IPv4/IPv6
TCP packets. Receive/send and rule decisions are mocked; parsing, packet
rewriting, connection tracking and the IPv4 PID cache use production code.
Neither this test nor `dll_load_test.c` opens the WinDivert driver.

Cases include stale DIRECT -> PROXY and BLOCK on a fresh SYN, PID eviction,
cross-family port reuse, SYN retransmissions, established proxied traffic,
DIRECT fast-path preservation, SYN+ACK, and FIN/RST cache retirement.
The DLL smoke test uses the GUI's loader, resolves all its required exports,
and adds/disables/enables/deletes an in-memory rule. CLI help/version are
checked separately.

These tests verify the cache defect deterministically. They do not prove that
the intermittent Codex timeouts have no other cause, and do not replace a real
driver/network test or a multi-hour soak test.

## Manual trial without replacing the installation

1. In the currently installed GUI, export a `.pbprofile` to a separate file.
2. When ready to switch traffic, fully exit the installed ProxyBridge (closing
   its window may only minimize it to the tray). Do not run both instances.
3. Open an administrator PowerShell in the extracted test-build directory and
   run the CLI with the exported profile and a separate log:

   ```powershell
   .\ProxyBridge_CLI.exe --profile 'C:\path\codex-test.pbprofile' --verbose 3 2>&1 |
       Tee-Object -FilePath .\soak-test.log
   ```

4. Use Codex normally over several hours, including idle periods and new chats.
   Confirm new Codex TCP connections appear as PROXY. If a request stalls,
   record the time and compare with an explicit SOCKS5 request:

   ```powershell
   curl.exe --proxy socks5h://127.0.0.1:8888 --connect-timeout 5 --max-time 15 -I https://chatgpt.com/
   ```

   An HTTP error such as 403 still demonstrates TCP/TLS reachability, not a
   successful authenticated Codex request. Preserve the test log and connection
   state before restarting if possible. Logs can contain destinations/processes;
   review them before sharing.
5. Press Ctrl+C to stop the test CLI, then reopen the installed ProxyBridge to
   roll back. No installed files need to be copied or restored.

The included GUI can also be used, but it shares `%APPDATA%\ProxyBridge` with
the installed GUI. Back up that directory before GUI testing; use the CLI with
an exported profile for the more isolated trial. Do not enable startup or use
the updater for this test build.

## Fix scope

Both IPv4 and IPv6 clear the per-port decision before the DIRECT fast path on
`SYN && !ACK`. IPv4 also retains its PID-cache eviction; IPv6 PID lookup does
not use that cache. FIN/RST uses the captured DIRECT verdict for the closing
packet after clearing the entry, preventing fall-through and re-caching.

This is a targeted lifecycle fix. The existing cache/connection table still
uses port-based keys; it does not implement full TCP-tuple isolation, change
UDP behavior, or redesign rule-edit invalidation.
