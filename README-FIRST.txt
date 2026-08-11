FIFA 15 TWO-PC TEST - REMOTE PLAYER f15b
========================================

You need only your installed FIFA 15 on a normal native x64 Windows PC.
Windows-on-ARM / Parallels is intentionally rejected because it is not a valid runtime for this test.

BEFORE THE TEST
- Close FIFA 15 completely.
- Make sure thankyounes has started the host-side two-PC test and left it running.
- Extract this package to a normal local folder; do not run it from inside the ZIP.

RUN
1. Double-click RUN-FIFA15-F15B.bat and approve the Windows administrator prompt.
2. Do not start FIFA yourself. The launcher first checks the package, Windows architecture,
   stale FIFA processes, the FIFA executable, the bundled LSX responder, private-network
   connectivity, host readiness, relay reachability, LSX port ownership, and hosts routing.
3. FIFA 15 is located automatically. If your install is in an unusual folder, select fifa15.exe
   in the file picker when asked.
4. The launcher then starts FIFA, verifies that the known certificate patch address is inside
   the launched FIFA image, applies the relay certificate, and reads it back for verification.
5. Only after the launcher says FIFA 15 is ready: Ultimate Team -> Online Single Match -> Search.
   Do not cancel once searching.
6. Close FIFA after the test. Cleanup runs automatically.
7. Send the FIFA15-F15B-EVIDENCE-*.zip from your Desktop to thankyounes.

IF IT STOPS
Do not improvise or manually edit your PC. Send thankyounes the exact STOP message shown by the launcher.
Emergency cleanup: CLEANUP-FIFA15-F15B.bat

IMPORTANT PRIVATE-NETWORK NOTE
This package needs either an already-connected Tailscale installation or a valid JOIN.key supplied
for this test. A join key that has expired or been revoked will be rejected with a clear STOP message.

Test ID: 20260811-225053
Package revision: hardening-v2
