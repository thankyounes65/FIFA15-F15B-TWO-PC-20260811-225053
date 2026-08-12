FIFA 15 TWO-PC TEST - REMOTE PLAYER f15b
========================================

You need only your installed FIFA 15 on a normal native x64 Windows PC.
Windows-on-ARM / Parallels is intentionally rejected because it is not a valid runtime for this test.

BEFORE THE TEST
- Close FIFA 15 completely.
- Make sure thankyounes has started the host-side two-PC test and left it running.
- Extract/clone this package to a normal local folder.
- Do not manually edit hosts, routes, Tailscale, Origin/EA, or drive mappings.

TAILSCALE / PRIVATE NETWORK
- If you already use Tailscale, STAY SIGNED INTO YOUR OWN ACCOUNT. Never sign into thankyounes' account.
- thankyounes should share only the host machine (configured host IP 100.91.142.54) with your Tailscale user.
- Accept that machine-share invite in your own account before running this package.
- RUN-FIFA15-F15B.bat verifies that the configured host actually appears in your Tailscale peer list before it changes anything.
- If Tailscale is not installed, the package can install it and use JOIN.key instead. JOIN.key is only for a private package and must never be published.

RUN
1. Double-click RUN-FIFA15-F15B.bat.
2. The read-only Tailscale preflight first checks whether the configured host is visible from your existing Tailscale account.
   If it prints TAILSCALE_HOST_NOT_SHARED, accept the machine-share invite and rerun the same BAT.
3. Approve the Windows administrator prompt when the main launcher asks for it.
4. The safety wrapper snapshots the exact hosts-file bytes/metadata/ACL plus the relevant
   Tailscale, EA Desktop/service, Z: drive and package-runtime pre-state before any test change.
5. The tester engine validates the package, Windows architecture, FIFA executable,
   bundled LSX responder, private-network connectivity, host readiness and relay reachability.
6. If Tailscale is absent, the bundled MSI is installed and JOIN.key is used automatically.
   If Tailscale already exists, the tester borrows the already-connected installation and does not log it out or switch accounts.
7. FIFA is launched automatically. The relay certificate is patched in FIFA memory and read back for verification.
8. Only after the launcher says FIFA 15 is ready: Ultimate Team -> Online Single Match -> Search.
   Do not cancel once searching.
9. Close FIFA after the test. Cleanup runs automatically.
10. Send the FIFA15-F15B-EVIDENCE-*.zip from your Desktop to thankyounes.

RESTORATION GUARANTEE
- The Windows hosts file is restored from its recorded pre-test bytes, not reconstructed or cleared.
- Any package-created Z: mapping and package-local runtime files are removed.
- If the package installed Tailscale, it logs out/uninstalls it; a pre-existing connected Tailscale installation is not reconfigured or logged out.
- EA Desktop running/stopped state and the relevant EA service states are restored to the recorded pre-test state.
- Emergency cleanup uses the same persistent snapshot: CLEANUP-FIFA15-F15B.bat.
- If restoration cannot be verified, the snapshot is deliberately retained and the window reports RESTORATION INCOMPLETE instead of pretending cleanup succeeded.

Two intentional artifacts are not restored: JOIN.key is deleted after a successful package-managed join for security,
and the evidence ZIP is left on the Desktop for the test report. Windows itself may also retain normal
OS audit/event/MSI history; this package does not erase forensic logs. Configuration touched by the
appliance is restored to its recorded pre-test values.

IF IT STOPS
Do not improvise or manually edit the PC. Send thankyounes the exact STOP/RESTORATION message.
Emergency cleanup: CLEANUP-FIFA15-F15B.bat

Test ID: 20260811-225053
Package revision: restore-v3 + shared-host-preflight-v1
