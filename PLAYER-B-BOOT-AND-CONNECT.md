# FIFA 15 Player B — complete boot/connect reconstruction

This document records the exact path that got the remote physical PC (`f15b`, Ian's machine during the 2026-08-12 investigation) from **cannot reliably start FIFA** to:

- FIFA 15 boots and stays alive;
- the preservation LSX layer is used;
- the relay CA patch is installed and verified;
- the tester connects through the host preservation relay;
- Ultimate Team opens;
- Online Single Match can queue against Player A;
- the two real physical clients can be paired by the relay.

It is intentionally more detailed than `README-FIRST.txt`. If a future tester machine fails, preserve its state and compare against this document plus `PLAYER-B-KNOWN-GOOD.json` before changing files.

## 1. Preservation / distribution rule

This public repository contains the launcher, routing, compatibility helpers, diagnostics, Tailscale bootstrap payload, and preservation CA modulus that we are permitted to distribute.

It **does not redistribute FIFA 15 game/crack DLLs**. Those files must come from a FIFA 15 installation the operator/tester is authorized to use. The repository records only filenames, sizes, hashes, provenance and compatibility observations.

Use:

```bat
VERIFY-PLAYER-B-GAME-FILES.bat
```

to compare a local installation against the exact recorded Player B state.

The machine-readable source of truth is `PLAYER-B-KNOWN-GOOD.json`.

## 2. What was actually proven

The final known-good Player B launch evidence established this chain:

1. native AMD64 Windows;
2. Tailscale connected on the tester's own account;
3. host `100.91.142.54` visible/reachable through the shared machine;
4. exact machine state snapshotted for restoration;
5. package-owned LSX responder takes `127.0.0.1:3216`;
6. EA App starts after LSX is already listening;
7. EA App reaches full readiness and remains stable for 10 seconds;
8. package LSX still owns 3216 after EA startup;
9. 14 FIFA/EA hostnames route to the host preservation relay;
10. DirtySDK demangler `peach.online.ea.com` deliberately stays local;
11. FIFA launches as x64;
12. FIFA loads `ItsAMe_Origin.dll` and `sysdllzf.dll` and survives early startup;
13. FIFA opens the local LSX connection;
14. after the proven 500 ms delay, the 128-byte OTG3 CA modulus is written into FIFA memory;
15. the write is read back and verified;
16. Player B's local loopback QoS/FUT sockets are forwarded to the physical host relay;
17. FIFA can enter Ultimate Team;
18. FIFA can enter Online Single Match and be paired with Player A.

The remaining matchmaking/peer-mesh work belongs to the host relay branch. Do **not** change this guest package merely because a later post-pair protocol experiment changes on the host.

## 3. External prerequisites

### Windows

Required/tested:

- native x64 / AMD64 Windows;
- administrator approval for temporary hosts-file/runtime operations;
- Windows-on-ARM / Parallels is intentionally rejected by the package.

### FIFA 15

The tester supplies their own authorized FIFA 15 installation.

The exact successful Ian executable was:

```text
fifa15.exe
bytes  = 87268816
SHA256 = 3DA97D0A568475E5714E06F4871B814842A705DDC62207C2B9B66B5FC085BFFB
```

Non-standard installation paths are supported: the launcher presents a file picker when it cannot auto-detect the game.

### Tailscale

The supported model is **machine sharing**, not credential sharing.

- Host shares the host machine with the tester.
- Tester signs into **their own** Tailscale account.
- Tester does not use the host owner's Tailscale credentials.
- Do not use a public `JOIN.key`.
- If Tailscale already exists and is connected, the package borrows it without reconfiguration/logout.
- If absent, the package can use the bundled signed MSI and normal browser authentication flow.
- Package-created Tailscale state is cleaned up after the run; a pre-existing connection is preserved.

Historical observed addresses:

```text
host:  100.91.142.54
guest: 100.101.2.29
```

Only the configured host address is part of the package contract; the guest address is observational and can change.

### EA App

The tester does **not** need the host owner's EA account.

Observed working EA App version during the successful comparison:

```text
13.764.6.6279
```

That exact version has not been independently proven mandatory. What **was** proven mandatory for Ian's early-start crash was allowing EA App to become fully ready before FIFA launch.

## 4. Exact game-file state recorded for Player B

`PLAYER-B-KNOWN-GOOD.json` is authoritative. Important entries are summarized here.

| File | SHA-256 | Evidence/status |
|---|---|---|
| `fifa15.exe` | `3DA97D0A568475E5714E06F4871B814842A705DDC62207C2B9B66B5FC085BFFB` | confirmed Ian + host |
| `ItsAMe_Origin.dll` | `5B141FB03C6F50228E48DDAF8DFB49428194A1F01BE1A63C826C5BCE4DEC487A` | confirmed Ian + host |
| `sysdllzf.dll` | `B477BACB277F43A9C93C4E4D8B47E1F0F8B6B2E9751A218448B8D1B17A5DCF87` | confirmed successful Ian state |
| `BCEnginezf.dll` | `009E8936E4E79499E189FE4A4E821B283FF8E830BE697F5E55873677BB4C3B01` | confirmed Ian + host |
| `CardsDLLzf.dll` | `51681FC42607CABAB2CB11B444078DDF6E9B1FBDC6A85DED9ECF43AC0F4D8C49` | confirmed Ian after manual copy + host |
| `dbdata.dll` | `FDDB8D45464CEF3FF089609DC71342D347AF62A36FB1E4AE8A75FBCA33DF88BF` | confirmed Ian + host |
| `d3dcompiler_46.dll` | `9614DE7BAC24091E2ABAF70B3C852DDF9B92A48157C557C3C63D81D88D4D5CEB` | confirmed Ian + host |
| `winui.dll` | `B4B1935EE76F434685F0515B0E5DFC18ADFD2DAEAE50F32EF85EC6FFAAADE63C` | confirmed Ian + host |
| `OriginSetup.exe` | `EC0765A1F39E55A39E378150270F39E90C93ADEE59272B947011232C3CED524D` | confirmed Ian + host, reference |
| `CPY.ini` | `8B6756120C45CF157A4E84F10CC29D7ED3BB6B077C035AD47A8FBE809FE5CF14` | confirmed Ian current baseline |
| `dlc\dlc_powdll\dlc\powdll\powdllzf.dll` | `D2005D098D2043C5E0B5050094548E809F6EE4A6FEC33D4AAE34056A378B42D0` | host/donor hash + operator reported copy to Ian; final Ian diagnostic did not recurse into this path |

### Important `sysdllzf.dll` warning

Do **not** replace Ian's successful `B477BACB...` copy merely because the host currently has:

```text
AE283399CA945FE910F819D61101A527A744753F6E0C46406C324C8721EE63F5
```

The latter is the known-working host's one-byte **debug-logging-enabled** variant. The logging byte is instrumentation, not a requirement for Player B startup. Ian successfully booted/connected with the original logging-disabled `B477BACB...` copy.

### CardsDLL provenance

Ian previously had:

```text
82D4A6E1E59DB6FFA7281DCC5FBA085C3AEC6326B6CAC12465E1511149BD8CB9
```

and later received the host's `51681F...` `CardsDLLzf.dll`.

FIFA had already crossed the early startup boundary before CardsDLL was isolated as a variable, so **do not claim CardsDLL was the EA/startup fix**. We preserve `51681F...` because it is the exact later baseline that reached FUT/matchmaking.

### `dbdata.dll` provenance

`dbdata.dll` was initially missing from Ian's install. The later exact baseline contains the host-matching `FDDB8D...` copy. Its individual necessity was not isolated from the EA-readiness fix; preserve it when reconstructing the exact baseline.

### POW DLL provenance

The operator reported manually copying the host POW DLL(s) to Ian. The known host/donor `powdllzf.dll` hash is recorded above. The final Ian startup fingerprint only audited top-level launch files, so it did not independently measure the nested POW DLL after the copy. Future diagnostics should recurse into that exact path before upgrading its status to `CONFIRMED_ON_IAN`.

## 5. Boot pipeline — why ordering matters

### 5.1 Exact-state wrapper first

`safe-run.ps1` snapshots the machine before temporary changes. The state is stored under:

```text
%ProgramData%\FIFA15-Preservation\
```

The wrapper protects/restores at minimum:

- exact hosts-file bytes/hash and metadata;
- relevant EA process/service state;
- package-created runtime/subst state;
- whether Tailscale pre-existed;
- package-created Tailscale state when applicable.

A failed restore is not silently accepted. The snapshot is retained and the run reports restoration incomplete.

### 5.2 LSX must own 3216 first

FIFA's Origin/EA SDK expects local LSX on:

```text
127.0.0.1:3216
```

The package starts `portable-lsx-responder.ps1` and verifies that **that package process** owns the listener.

Do not merely check “something is listening on 3216.” EA Desktop itself can own the port, and that was one of the startup-state ambiguities investigated during bring-up.

### 5.3 Start EA App behind package LSX

After LSX owns the port, the package starts/permits the real EA App compatibility processes.

The critical fix for Ian's 100–250 ms process death was an EA **readiness gate**, not a different FIFA executable and not the CA patch.

Before FIFA launches the package requires:

```text
EADesktop.exe          >= 1
EABackgroundService    Running
EALocalHostSvc.exe     >= 1
EACefSubProcess.exe    >= 1
package LSX still owns 127.0.0.1:3216
```

That condition must remain stable for **10 seconds**. Readiness timeout is **60 seconds**.

If EA never becomes ready, FIFA should not be launched. If EA steals/breaks LSX during startup, FIFA should not be launched.

This was the decisive startup fix. Before it, the same exact FIFA executable and known Origin DLL loaded, FIFA survived roughly 100 ms, then died before the 500 ms CA patch point. After the gate, FIFA survived, connected to LSX, and reached the CA write/readback.

## 6. Hostname routing contract

`fifa15-managed-hostnames.ps1` is the single source of truth. These names route to the configured host relay address:

```text
gosredirector.ea.com
gosredirector.online.ea.com
gosredirector.stest.ea.com
gosredirector.scert.ea.com
spring14.gosredirector.ea.com
spring14.gosredirector.online.ea.com
spring14.gosredirector.stest.ea.com
spring14.gosredirector.scert.ea.com
pal.lt.easfc.ea.com
content.lt.easfc.ea.com
easw.easports.com
xmlns.easw.easports.com
eac-fifapow02.eac.ad.ea.com
fifa.easports.com
```

The four `spring14.*` names matter. Earlier scripts had independent copied hostname arrays and one incomplete writer could silently remove them, allowing FIFA to escape to a real/decommissioned EA endpoint. Do not duplicate this list again; dot-source the canonical file.

DirtySDK demangler is intentionally different:

```text
peach.online.ea.com -> 127.0.0.1
```

on Player B.

## 7. Why the guest needs loopback forwarding

Once FIFA booted and connected to Blaze/POW, Ian still could not enter Ultimate Team.

The relay publishes two literal loopback endpoints that are valid when FIFA and relay live on the **same PC**:

```text
QoS      127.0.0.1:17502
FUT REST 127.0.0.1:17503
```

On a physical remote PC, `127.0.0.1` means the guest itself. That was the first divergence: the host performed QoS and `POST ut/auth`, while Ian performed neither.

The public guest package therefore starts `loopback-relay-forwarder.ps1`, which creates only these two transparent TCP routes:

```text
127.0.0.1:17502 -> 100.91.142.54:17502
127.0.0.1:17503 -> 100.91.142.54:17503
```

It does not terminate TLS, rewrite HTTP, modify auth, or parse packets. It copies bytes.

Do not add speculative forwarders just because another literal `localhost` exists somewhere in code. The physical-PC evidence already proved the hostname-routed redirector, Blaze, content, EASW and POW paths were reaching the host correctly.

The forwarder writes a Desktop log:

```text
FIFA15-F15B-FORWARDER-YYYYMMDD-HHMMSS.log
```

and must print:

```text
F15B_LOOPBACK_FORWARDER_READY
```

before the main launch proceeds.

## 8. Relay/server ports relevant to Player B

Core preservation relay listeners on the host:

```text
42127  raw redirector/preflight reachability
42230  HTTPS redirector
42128  Blaze game server
17502  QoS/TLS
17503  FUT REST
```

Other hostname-routed HTTP services used during the proven Player B path included content/EASW/POW services on host-side ports managed by the relay. Their DNS routing comes from `fifa15-managed-hostnames.ps1`; they did not need guest-local loopback forwarders.

Host readiness beacon:

```text
TCP 48215
```

The guest should not proceed into FIFA until the host explicitly reports ready and TCP 42127 is reachable.

## 9. Certificate patch contract

The package contains:

```text
ca_modulus_1024.bin
bytes  = 128
SHA256 = 5A6C7E9A1DAF98099BBE5C97C4ABD5FE6315FDDA4439F77A18635EE56C146A3A
```

For the exact successful executable/module layout:

```text
module base       = 0x140000000
absolute address  = 0x141E1F1A0
RVA               = 0x01E1F1A0
length            = 128 bytes
```

The proven launch sequence attaches to the FIFA process/module, waits **500 ms**, performs one direct write of the 128-byte modulus, then reads it back and compares the bytes.

Do not move the write earlier merely because a process has appeared. The bring-up work explicitly separated process existence/module readiness from the known-good patch timing.

## 10. Exact operator run sequence

### Host / Player A

Player A starts the coordinator-selected host runtime branch and waits for its READY/profile-A proof.

The guest repository is intentionally not tied to every matchmaking branch. A host matchmaking experiment can change while Player B keeps the same stable boot/connect package.

### Guest / Player B

1. Use the current public repo folder.
2. Do not manually edit hosts.
3. Do not replace DLLs unless the file audit or a specifically documented experiment requires it.
4. Optional but strongly recommended before a new machine/test rebuild:

```bat
VERIFY-PLAYER-B-GAME-FILES.bat
```

5. Run:

```bat
RUN-FIFA15-F15B.bat
```

6. Approve administrator elevation.
7. If Tailscale browser auth appears, use the tester's own account.
8. Wait for all automated preflight/readiness/CA checks.
9. Only after FIFA is declared ready, navigate as requested by the current host runtime test.
10. Close FIFA when the scenario is complete. Let automatic restoration finish.

## 11. What the launcher should prove before game navigation

Healthy output should establish, in order:

```text
native architecture AMD64
Tailscale host visible
host READY + TCP 42127 reachable
exact restoration snapshot written
package validation PASS
fifa15.exe x64 + hash recorded
package LSX owns 3216
EA readiness observed
EA readiness stable for 10 seconds
package LSX still owns 3216
14 relay hostnames + local peach pin verified
FIFA process/module attached
500 ms CA delay
OTG3 modulus direct write
128-byte readback verified
FIFA 15 ready
```

For the current complete remote-FUT package the outer BAT also needs:

```text
F15B_LOOPBACK_FORWARDER_READY ... ports=17502,17503
```

## 12. Diagnostics to keep

Every run writes:

```text
Desktop\FIFA15-F15B-DIAG-YYYYMMDD-HHMMSS.txt
```

The remote loopback forwarder writes:

```text
Desktop\FIFA15-F15B-FORWARDER-YYYYMMDD-HHMMSS.log
```

Useful diagnostic content includes:

- package root/revision;
- Tailscale IP and host visibility;
- exact FIFA executable path/hash;
- early companion hashes;
- EA process family/readiness;
- LSX ownership and first FIFA LSX socket;
- certificate write/readback state;
- top-level game-file fingerprint;
- restoration result.

When debugging future machines, add recursive fingerprinting for any nested DLC file being manually supplied, particularly `dlc\dlc_powdll\dlc\powdll\powdllzf.dll`.

### Important historical diagnosis boundaries

Bring-up failures and what fixed/refuted them:

- `TAILSCALE_NOT_INSTALLED` / host not shared: establish tester-owned Tailscale + machine share.
- transient hosts lock: retry only the hosts-file `IOException`; preserve exact restore verification.
- PowerShell launch/null race: launcher hardening/null checks.
- FIFA dies ~100–250 ms after process start: **EA App readiness**, not CA; fixed by the full-readiness + 10 s stability gate.
- FIFA boots/Blaze works but Ultimate Team cannot open: guest `127.0.0.1:17502/17503` pointed to the wrong physical machine; fixed by the two transparent forwarders.
- Host became `f15b` after reconnect: host-side order-based identity allocation/release race; fixed/guarded on the host harness, not by changing the guest boot package.
- Two physical clients pair then fail post-GameSetup: matchmaking/peer-mesh host protocol problem; do not contaminate the stable guest startup baseline while investigating it.

## 13. Restoration contract

The package must restore what it temporarily changes.

Expected behavior:

- hosts restored byte-for-byte and hash verified;
- temporary hosts block removed;
- package runtime/subst state removed;
- pre-existing EA state/services restored;
- pre-existing Tailscale preserved;
- package-created Tailscale session/install cleaned up according to bootstrap policy;
- forwarder stopped;
- persistent recovery snapshot retained if restoration cannot be verified.

Emergency command:

```bat
CLEANUP-FIFA15-F15B.bat
```

Do not treat a run with incomplete restoration, wrong host branch, missing required package component or failed preflight as protocol evidence.

## 14. Files in this repo that matter to reconstruction

### User-facing

- `RUN-FIFA15-F15B.bat` — complete run wrapper.
- `CLEANUP-FIFA15-F15B.bat` — emergency/explicit cleanup.
- `README-FIRST.txt` — short operator instructions.
- `VERIFY-PLAYER-B-GAME-FILES.bat` — one-click exact baseline audit.
- `PLAYER-B-BOOT-AND-CONNECT.md` — this complete record.
- `PLAYER-B-KNOWN-GOOD.json` — machine-readable known-good state.

### Network/bootstrap

- `tailscale-bootstrap.ps1`
- `tailscale-preflight.ps1`
- `loopback-relay-forwarder.ps1`
- `fifa15-managed-hostnames.ps1`
- `APPLIANCE-CONFIG.json`

### Safe execution / diagnostics

- `safe-run.ps1`
- `launch-safe.ps1`
- `diagnostic-run.ps1`
- `remote-client.ps1`
- `portable-lsx-responder.ps1`

### Package-integrity assets

- `PACKAGE-MANIFEST.json`
- `ca_modulus_1024.bin`
- bundled signed Tailscale MSI (when present in the package)

## 15. Maintenance rules for future work

1. **Do not silently change Player B game DLLs.** Record the old/new hash and why.
2. Update `PLAYER-B-KNOWN-GOOD.json` only after evidence proves a new exact baseline.
3. Keep “confirmed on Ian” separate from “copied/reported from host”.
4. Do not call a file required merely because it was present during success. Isolate necessity when practical.
5. Never make the host's debug `sysdllzf.dll` variant a Player B requirement unless runtime evidence actually requires it.
6. Keep the canonical hostname list in one file.
7. Forward only literal-loopback services that physical-PC evidence proves need forwarding.
8. Keep the guest boot/connect package stable while host-side matchmaking experiments change.
9. Preserve diagnostics from any failure before changing another variable.
10. Do not commit proprietary FIFA/crack binaries to this public repository without explicit redistribution rights; commit hashes/provenance/verifiers instead.

## 16. Current preservation milestone

As of the 2026-08-12 two-PC work, this repository is sufficient to represent the **known working Player B boot/connect path**. The remote PC has successfully:

```text
booted FIFA
-> connected to package LSX
-> passed CA patch verification
-> connected through the host preservation services
-> entered Ultimate Team
-> entered Online Single Match
-> paired with the host client
```

The active unresolved boundary is later: paired `GameSetup` -> real DirtySDK peer mesh / gameplay transition. That work belongs to the host relay runtime branch and should be investigated without destabilizing this guest baseline.
