FIFA 15 TWO-PC TEST - REMOTE PLAYER f15b
========================================

CURRENT MATCHMAKING RUNTIME - 2026-08-15
Player B is the dedicated portable repo/package for:

  Candidate: FIFA15-MM-V14-0X0B
  Player A: integration/test-matchmaking-session-completion-0x0b-v14
  Package token: F15B-GITHUB-KNOWN-GOOD-20260811-V14-0X0B-1

Use a FRESH GitHub ZIP of this repo's main branch and extract it normally.
A Git clone / .git directory is NOT required. RUN-FIFA15-F15B.bat validates
APPLIANCE-CONFIG.json + PACKAGE-MANIFEST.json and completes the exact candidate
handshake with Player A before FIFA is touched. An old v13 package cannot pass
the v14 package-token gate.

CURRENT PRESERVATION MILESTONE
This package has now been proven on a real remote x64 Windows PC through:

  FIFA boots and survives startup
  -> package LSX connection
  -> relay CA patch + readback
  -> preservation relay connectivity
  -> Ultimate Team
  -> Online Single Match
  -> two-player matchmaking pairing with the host

The remaining active work is AFTER pairing (GameSetup -> real peer mesh/gameplay/session completion).
Do not change Player B game files for a host-side matchmaking experiment unless the runtime test
explicitly requires it.

IMPORTANT DOCUMENTATION
- PLAYER-B-BOOT-AND-CONNECT.md  complete reconstruction, failure history, networking and cleanup
- PLAYER-B-KNOWN-GOOD.json      machine-readable exact successful Player B state/hashes
- VERIFY-PLAYER-B-GAME-FILES.bat read-only audit of a local FIFA install against that state

This public repo does NOT redistribute proprietary FIFA/crack DLLs. It records filenames/hashes and
verifies files supplied by an installation you are authorized to use.

SUPPORTED PC
- Native AMD64/x64 Windows.
- Windows-on-ARM / Parallels is intentionally rejected.
- Administrator approval is required for temporary hosts/runtime operations.

BEFORE RUNNING
1. Make sure FIFA 15 itself is installed.
2. Accept thankyounes' Tailscale MACHINE-SHARE for the host using YOUR OWN Tailscale account.
3. Do not use thankyounes' Tailscale or EA account credentials.
4. Do not use a JOIN.key from a public repository.
5. Do not manually edit the Windows hosts file.
6. Do not copy more game DLLs unless a documented test calls for it.

For a newly reconstructed/tester installation, first run:

  VERIFY-PLAYER-B-GAME-FILES.bat

The exact successful Player B executable was:
  fifa15.exe SHA-256
  3DA97D0A568475E5714E06F4871B814842A705DDC62207C2B9B66B5FC085BFFB

See PLAYER-B-KNOWN-GOOD.json for the exact successful companion-file state. In particular, the
successful Player B sysdllzf.dll is the logging-DISABLED B477BACB... copy; do not replace it merely
because the host uses a one-byte debug-logging variant.

TAILSCALE
If Tailscale is already installed/connected, the package borrows it without reconfiguration/logout.
If it is absent, the package can install the bundled signed MSI and use Tailscale's normal browser
login. Use YOUR OWN account. Package-created Tailscale state is cleaned up after the run; pre-existing
Tailscale is preserved.

HOST / NETWORK
Configured host preservation address:
  100.91.142.54

The launcher waits for the host READY beacon and proves TCP 42127 is reachable.
The canonical EA/FIFA hostname list is fifa15-managed-hostnames.ps1. Those 14 names route to the
host. peach.online.ea.com deliberately remains pinned to 127.0.0.1 on Player B.

Two literal loopback services need special handling on a physical remote PC. RUN-FIFA15-F15B.bat
starts a transparent byte-for-byte forwarder before FIFA:

  127.0.0.1:17502 -> 100.91.142.54:17502   QoS/TLS
  127.0.0.1:17503 -> 100.91.142.54:17503   FUT REST

Healthy startup includes:
  F15B_LOOPBACK_FORWARDER_READY

EA / LSX STARTUP ORDER - DO NOT SHORTEN
The early Ian crash was fixed by waiting for EA App readiness. The package must:

1. make the package LSX responder own 127.0.0.1:3216;
2. start/allow EA App behind that listener;
3. require EADesktop.exe;
4. require EABackgroundService Running;
5. require EALocalHostSvc.exe;
6. require at least one EACefSubProcess.exe;
7. require package LSX still owns 3216;
8. hold that state stable for 10 seconds;
9. only then launch FIFA.

Readiness timeout is 60 seconds. If this state is not reached, FIFA should NOT be launched.

CERTIFICATE PATCH
After FIFA/module attach, the package follows the proven timing:
  wait 500 ms
  -> write the 128-byte OTG3 modulus
  -> read it back
  -> require exact verification

Only after the launcher says FIFA 15 is ready should you navigate the game.

RUN
1. On Player A, start the Universal Tester v14 Matchmaking runtime and leave it at the peer gate.
2. Double-click RUN-FIFA15-F15B.bat in this fresh extracted Player B folder and approve the administrator prompt.
3. Complete Tailscale browser login with YOUR OWN account only if requested.
4. Require the v14 package self-test and A/B candidate handshake to PASS before FIFA starts.
5. Wait for all automated preflight, EA readiness, routing, forwarder and CA checks.
6. Follow the current host runtime test's FIFA actions.
7. Close FIFA when that scenario is finished. Cleanup is automatic.

IF FIFA IS NOT AUTO-DETECTED
Select the real fifa15.exe in the file picker. Non-standard paths are supported; the executable hash
is recorded.

DIAGNOSTICS
Every run writes:
  Desktop\FIFA15-F15B-DIAG-YYYYMMDD-HHMMSS.txt

The QoS/FUT forwarder writes:
  Desktop\FIFA15-F15B-FORWARDER-YYYYMMDD-HHMMSS.log

If anything fails, preserve/send BOTH newest files before changing another variable.

RESTORATION
- hosts file is restored from recorded pre-test bytes and verified by SHA-256;
- package runtime/subst state is removed;
- EA Desktop/service state is restored;
- pre-existing Tailscale is preserved;
- package-created Tailscale state is cleaned up according to bootstrap policy;
- loopback forwarder is stopped;
- if restoration cannot be verified, the persistent snapshot remains and the run reports failure;
- emergency cleanup: CLEANUP-FIFA15-F15B.bat

Test family: FIFA15 remote Player B / f15b
Guest runtime: ea-readiness-v1 + loopback-forwarder-17502-17503
For full details, read PLAYER-B-BOOT-AND-CONNECT.md.
