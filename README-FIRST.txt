FIFA 15 TWO-PC TEST - REMOTE PLAYER f15b
========================================

THIS PACKAGE IS FOR A NORMAL NATIVE x64 WINDOWS PC.
The next runtime target may use a cracked FIFA 15 build. That is fine: the launcher validates the
actual fifa15.exe as x64 and records its SHA-256 instead of requiring one specific game hash.
Windows-on-ARM / Parallels is intentionally rejected.

BEFORE RUNNING
1. Make sure FIFA 15 itself is a complete install and fifa15.exe launches normally.
2. Accept thankyounes' Tailscale machine-share invite for the host PC using YOUR OWN Tailscale account.

You do NOT need to install Tailscale manually. If it is absent, RUN-FIFA15-F15B.bat installs the
bundled signed MSI automatically and invokes Tailscale's normal browser login. Sign in with YOUR OWN
Tailscale account. Never use thankyounes' Tailscale login.

If Tailscale was already installed before the test, the package does not reconfigure or log it out.
If the package installs Tailscale for this test, it disables Tailscale DNS for the temporary session
(to avoid the EA DNS failure seen on the previous tester) and removes Tailscale again after the run.

DO NOT use a JOIN.key copied from this public repository. The supported path is your own account
plus the shared host machine.

Leave EA App / Origin exactly as it already is. Do not close it just for this test. If no EA Desktop
installation exists, the package has its own process-presence/LSX compatibility path.

RUN
1. thankyounes starts RUN-TWO-PC-HOST.bat and leaves it running.
2. Double-click RUN-FIFA15-F15B.bat and approve the Windows administrator prompt.
3. If Tailscale is missing, it is installed automatically. Complete the browser login with YOUR OWN account.
4. The launcher proves that your Tailscale account can see thankyounes' shared host.
5. It waits for the host READY beacon and proves relay TCP 42127 is reachable.
6. It snapshots the machine state, prepares LSX on 127.0.0.1:3216, installs temporary FIFA hosts
   routing, launches FIFA, patches the relay CA modulus in memory, and verifies the readback.
7. Only after it prints that FIFA 15 is ready: Ultimate Team -> Online Single Match -> Search.
8. Do not cancel once searching.
9. Close FIFA after the test. Cleanup is automatic.

IF FIFA IS NOT AUTO-DETECTED
A file picker may appear. Select the real fifa15.exe from the FIFA 15 install folder. Non-standard
paths are supported through that picker and the executable hash is recorded.

DIAGNOSTICS
Every run/failure writes a file to the Desktop:
  FIFA15-F15B-DIAG-YYYYMMDD-HHMMSS.txt

If anything fails, send the newest file to thankyounes. It includes the first known failure boundary,
for example TAILSCALE_LOGIN_FAILED, TAILSCALE_HOST_NOT_SHARED, HOST_NOT_READY, LSX_PORT_CONFLICT,
CERTIFICATE_PREIMAGE_READ_FAILED, FIFA_EXITED_DURING_LAUNCH, or RUNTIME_LAUNCH_VERIFIED.
The BAT also pauses on failure so the message does not disappear.

RESTORATION
- The Windows hosts file is restored from its recorded pre-test bytes and verified by SHA-256.
- Package-created Z: and runtime files are removed.
- A pre-existing connected Tailscale installation is not reconfigured or logged out.
- If the package installed Tailscale because it was absent, the package logs out/uninstalls that
  temporary installation after the test and verifies that Tailscale is absent again.
- EA Desktop running/stopped state and relevant service states are restored to the recorded state.
- If restoration cannot be verified, the persistent snapshot is retained and the window reports
  RESTORATION INCOMPLETE instead of pretending cleanup succeeded.
- Emergency cleanup: CLEANUP-FIFA15-F15B.bat

Test ID: 20260811-225053
Package revision: shared-host-v5-auto-tailscale
