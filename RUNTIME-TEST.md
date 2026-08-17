# FIFA15 Player B Working-Server Parity

**Subsystem:** FUT Online Single Match matchmaking - NotifyGameSetup conformance to a real working server

**Purpose:** Player A's relay now sends a `NotifyGameSetup` that matches a captured, **working** FIFA 15 server field for field. This run measures whether the clients get further than they did before. Player B's job is only to be a normal second client.

**Player B branch:** `integration/test-matchmaking-working-server-parity-v1`

**Player A required branch:** `thankyounes65/fifa15-relay-clean` / `integration/test-matchmaking-working-server-parity-v1`

**No instrumentation.** Nothing is attached to `fifa15.exe` on this machine. There is no Frida, no Interceptor, no Stalker, no injected DLL, and no Python dependency to install. Run 20260817 crashed FIFA on **both** machines while Frida was attached, so it is gone. Progress is measured entirely from Player A's relay log, because every Blaze message both clients send crosses that relay.

**Package contract (unchanged):** portable extracted folder. `requires_git_checkout=false`, `sends_exact_repo_commit=false`, `portable_extracted_folder_supported=true`. No Git and no development environment is needed.

**Binary/runtime state:** `PLAYER-B-KNOWN-GOOD.json` and `VERIFY-PLAYER-B-GAME-FILES.ps1` remain authoritative. Retail `fifa15.exe` SHA-256 `3DA97D0A568475E5714E06F4871B814842A705DDC62207C2B9B66B5FC085BFFB`. **No game file is modified.** The existing boot, Tailscale, hosts-routing, loopback-forwarder, LSX, certificate-patch and network-observer stack is unchanged.

**What changed on Player A**, taken from the capture of the working server and detailed in `docs/MATCHMAKING-WORKING-SERVER-GAMESETUP-DIFF.md`:

| field | was | now (matches working server) |
| --- | --- | --- |
| `PROS[i].CONG` | fabricated group `1515100001/2` | the player's own Blaze id |
| `PROS[i].UGID` | `objid(0,0,0)` | `objid(30722, 2, PID)` |
| `PHST.CONG` / `THST.CONG` | fabricated group | `HPID` |
| `GSTA` | `130` up front | `1`; the client drives 130 itself |
| `STAT` | `4` host / `2` guest | `2` for both |
| `TCAP` / `VOIP` | `1` / `2` | `0` / `0` |
| `GID` | 56-bit `0xC0FFEE…` | 24-bit, `SEED == GID`, `GNAM == UUID == "game"+GID` |
| top level | `GAME PROS QUEU REAS QOSS QOSV LFPJ TELM` | `GAME PROS REAS` (ascending, as Blaze requires) |
| dropped entirely | `COID ESNM GGTY GMRG PGID PGSR TIDS BLOB QUEU QOSS QOSV LFPJ TELM` | the working server sends none of them |

**Exact actions:** run `RUN-FIFA15-F15B.bat` as Administrator while Player A waits in its peer gate. When both clients are up, enter FUT Online Single Match; **A searches first, B second**. Do not cancel, retry, or pick any old scenario. Close FIFA normally when the attempt resolves.

**Stale helpers:** the launcher reclaims anything a previous crashed run left behind before starting its own. An unrelated process holding a recycled PID is never killed. The operator never has to kill a PID by hand.

**Evidence:** this package writes `runs/matchmaking-working-server-parity/player-b/<timestamp>/RUN-MANIFEST.txt`, plus the usual network-observer, forwarder and diagnostic logs. `COLLECT-PLAYER-B-EVIDENCE.ps1` runs automatically at the end - **including after a crash** - and drops one ZIP on the Desktop containing the manifest, the Desktop logs, any `fifa15` crash dump (recording the path instead of copying when it is multi-GB), Windows Error Reporting records and recent Application error events. Send that ZIP.

**How progress is judged** (on Player A, from the relay log):

```
python scripts/score-matchmaking-progress.py --relay-log <run>/relay-full.log
```

Baseline to beat, from the last pre-parity run `20260817-013523`:

| milestone | before | working server |
| --- | ---: | ---: |
| StartMatchmaking answered | 2 | 2 |
| NotifyGameSetup delivered | 2 | 2 |
| **updateMeshConnection received** | **1** | **3** |
| **telemetry reports** | **0** | **~2170** |

`updateMeshConnection` is the decisive one: the client only sends it once it can resolve the peer's connection group out of the roster, which is exactly what `CONG`/`UGID` now carry.

**Success:** more `updateMeshConnection` than before, and any telemetry at all, would be real forward progress. A shared lobby would be more. **Neither is required for the run to be informative** - a changed scorecard is the measurement.

**VOID:** wrong A/B branch, known-good file verification failure, peer attestation failure, stale FIFA process, missing relay log, or any reintroduction of in-process instrumentation on either machine.
