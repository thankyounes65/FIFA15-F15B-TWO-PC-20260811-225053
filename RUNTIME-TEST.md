# FIFA15 Player B Matchmaking Native Observer

**Subsystem:** FUT Online Single Match matchmaking - logical joiner MatchSession success boundary

**Purpose:** one synchronized, read-only, unchanged-wire capture with Player A. There is no scenario selector and no protocol candidate on Player B.

**Player B branch:** `integration/test-matchmaking-native-observer-v2`

**Player A required branch:** `thankyounes65/fifa15-relay-clean` / `integration/test-matchmaking-native-observer-v2`

**Why v2 replaces v1:** v1 is **VOID**. In run `20260817-001802` Player A's v1 observer armed correctly and its two Interceptor hooks ran for ~103 s, then `Stalker.follow` was called on the GameSetup thread (tid 43904) and `fifa15.exe` died 4 s later with `0xC0000005` on that same thread, at `RIP=0x1199C110F` inside Frida Stalker's own 4 MB `PRIVATE`/`RWX` code-cache slab (`0x1199C0000+0x400000`), executing a relocated `mov rax,[rip+0xB84850]` whose effective address `0x11A545966` fell in the `FREE`/`NOACCESS` region that begins exactly at the end of that slab. `frida-agent.dll` is in the dump's module list and the faulting RIP is in none of the 139 loaded modules, so no `fifa15.exe` code was involved. Zero Stalker callouts ever fired. Player B carried the same Stalker design and would have failed the same way. **v2 removes Stalker entirely and keeps only Frida Interceptor**, which the same run proved stable in this process.

**Package contract (unchanged):** portable extracted folder. `requires_git_checkout=false`, `sends_exact_repo_commit=false`, `portable_extracted_folder_supported=true`. No Git and no development environment is needed on Player B. Frida is still used, is still pinned, and is still installed **package-locally** into `.observer-deps`; nothing is installed globally.

**Binary/runtime state:** existing `PLAYER-B-KNOWN-GOOD.json` and `VERIFY-PLAYER-B-GAME-FILES.ps1` remain authoritative for the Player B game/DLL set. The observer targets retail `fifa15.exe` SHA-256 `3DA97D0A568475E5714E06F4871B814842A705DDC62207C2B9B66B5FC085BFFB` and uses the existing boot, Tailscale, loopback-forwarder, LSX, certificate-patch and network-observer stack unchanged. **No game file is modified** - there is no byte patch, code cave or detour written to disk; all instrumentation is in-process and vanishes when FIFA exits.

**Observer targets (11 read-only Interceptor probes):**

| probe | module + RVA | answers |
| --- | --- | --- |
| `gamesetup_virtual_success_callsite` | fifa15 `0x47BCC76` | GameSetup virtual-success callsite (anchor 2 instructions before `0x47BCC7C call [rax+8]`, same basic block) |
| `matchmaking_operation_plus8` | fifa15 `0x479EBE9` | operation `+8` continuation |
| `matchmaking_operation_plus28` | fifa15 `0x479B785` | adjacent operation `+0x28` hop |
| `matchmaking_reas3_result_apply` | fifa15 `0x479BC0B` | discriminator-3 MatchSession result application |
| `matchsession_bridge_entry` | fifa15 `0x3A04A32` | bridge, result code, incoming session, `bridge+0x98` active session, **both compared MSIDs** |
| `matchsession_bridge_owner_match` | fifa15 `0x3A04A65` | fires **only** when `*active == *incoming`, i.e. the incoming MSID still owns the bridge |
| `event_matchup_success_emitter` | fifa15 `0x3715903` | whether `EVENT_MATCHUP_SUCCESS` is emitted |
| `zero_b_window_entry` | fifa15 `0x47BE327` | the `0x0B` window was entered at all |
| `zero_b_result4_destroy` | fifa15 `0x47BE3D9` | **`0x0B` = result-4 destroy** |
| `zero_b_virtual_plus8_arm` | fifa15 `0x47BE416` | **`0x0B` = virtual `+8` arm**, plus the two gate bytes deciding whether `call [rax+8]` executes |
| `cards_get_squad_list` | CardsDLLzf `0x3BAB0` | GetSquadList entry on Player B |

**Safety/evidence rule:** every probe verifies its target's live bytes against a blob pinned from decrypted runtime memory and is **never armed unless the bytes match** (`fifa15.exe` is packed, so on-disk bytes are not the executed bytes). No probe alters registers, flags, stack, branches, network messages or lifecycle state. Per-probe emission is capped at 200 with explicit saturation reporting. A probe that was never armed is reported **Not Reached**, never as a negative result.

**Exact actions:** run `RUN-FIFA15-F15B.bat` as Administrator while Player A is waiting in its matching observer peer gate. After both FIFA clients are launched, enter FUT Online Single Match; **A searches first and B second**. Do not cancel, retry, or select any old scenario. Close FIFA normally after the first divergence window is captured.

**Stale helpers:** the launcher now reclaims anything a previous crashed or aborted run left behind before starting its own helpers. The `a Player B network observer is already running` failure mode is resolved: observer identity is confirmed against the recorded start time, a genuinely orphaned helper is stopped automatically, and a dead or recycled PID is discarded. An unrelated process that happens to hold a recycled PID is **never** killed. Under normal operation the operator never has to kill a PID by hand.

**Diagnostic success:** Player B evidence proves whether its MatchSession bridge still owns the incoming MSID, whether `EVENT_MATCHUP_SUCCESS` is emitted, which `0x0B` lifetime path executes, and whether CardsDLL `GetSquadList` is entered. UI success is useful evidence but is not required for the diagnostic to resolve the question.

**Evidence:** `runs/matchmaking-native-observer/player-b/<timestamp>/` containing `matchmaking-native-observer-v2.jsonl`, `matchmaking-native-observer-v2.txt`, `OBSERVER-VERDICT.txt` and `OBSERVER-RUN-MANIFEST.txt`, plus normal Player B network/diagnostic artifacts from the inherited stack, all bound into the evidence ZIP.

**VOID:** wrong A/B branch, known-good file verification failure, peer attestation failure, observer not live, any `probe_byte_mismatch` on a relied-upon probe, Frida/script error, stale FIFA process, truncated decision-window evidence, or **any reintroduction of Stalker**.
