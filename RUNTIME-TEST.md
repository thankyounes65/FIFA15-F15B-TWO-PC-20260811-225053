# FIFA15 Player B Working-Server Setup Burst v3

**Subsystem:** FUT Online Single Match matchmaking — the notification burst the real server pushes between `NotifyGameSetup` and the client's first mesh request.

**Player B branch:** `integration/test-matchmaking-working-server-setup-burst-v3`

**Player A required branch:** `thankyounes65/fifa15-relay-clean` / `integration/test-matchmaking-working-server-setup-burst-v3`

**Player A build:** `build_pairing_working_server_setup_burst_v3.rs`

**Candidate/package:** `FIFA15-MM-WORKING-SERVER-SETUP-BURST-V3` / `F15B-MM-WORKING-SERVER-SETUP-BURST-V3`, peer gate TCP 48216.

**No instrumentation.** Nothing is attached to `fifa15.exe` on either machine. Player B remains a normal second client using the already-proven Tailscale/hosts/loopback/LSX/certificate/evidence stack. Retail `fifa15.exe` SHA-256 remains `3DA97D0A568475E5714E06F4871B814842A705DDC62207C2B9B66B5FC085BFFB` and no game file is modified. **Player B's wire is unchanged in this candidate** — the only variable is Player A's burst.

## Already Confirmed, and not under test

Run `20260817-064947` proved Leads 1–3 end to end, and Player A inherits them
unchanged here:

- every mesh `TCG` resolved to the real peer (0 unknown, previously all unknown);
- self announcements never promote; the genuine cross-player CONNECTED edge does;
- `GSTA=130` is held until that edge arrives;
- both players then receive `GSTA130 → STAT=4 ×2 → JoinCompleted ×2`, once each, with no premature host `JoinCompleted`;
- neither client sends `leaveGameByGroup` any more.

The shared lobby still did not appear, which is why this run exists.

## Exact hypothesis

The plaintext capture of a real successful FIFA 15 session shows four
notifications between `NotifyGameSetup` and the client's first
`updateMeshConnection`, back-to-back with no client traffic in between:

```
S 0x0014  GameSetup, REAS.VALU.MSID = this client's own session
S 0x00E7  GID only
S 0x0016  GameSetup, byte-identical except REAS.VALU.MSID = the PEER's session
S 0x0064  GID + GSTA = 1
S 0x00C9  DONE/GLID/REMV/UPDT
C 0x001D  updateMeshConnection
```

Run `20260817-064947` sent none of `0x00E7` or `0x0064(GSTA=1)`, sent no
`0x0016` to the host at all, and gave the guest a `0x0016` carrying its own
session id rather than the peer's. Player A v3 emits the first three to **both**
clients in the captured order and position.

`0x00C9` is deliberately **not** reproduced: only its field names were ever
observed, with no types, values, order or counts, so building it would mean
inventing a wire document.

## Exact actions

1. Player A uses the Universal Branch Tester and selects `integration/test-matchmaking-working-server-setup-burst-v3`.
2. Player A must require `launch\VERIFY-BUILD.bat` to PASS before FIFA starts.
3. Player B uses a FRESH ZIP of this exact branch and runs `RUN-FIFA15-F15B.bat` as Administrator.
4. Require the peer gate to accept exact candidate/package `FIFA15-MM-WORKING-SERVER-SETUP-BURST-V3` / `F15B-MM-WORKING-SERVER-SETUP-BURST-V3`.
5. Both enter FUT → Online Single Match. **A searches first, B searches second.**
6. Do not cancel or retry after pairing.
7. If both reach the shared lobby, B readies first, then A. Continue toward kickoff only while stable.
8. If the joiner remains loading, leave the state visible briefly so evidence flushes, then close FIFA normally.

## Primary discriminator

Player A evidence must show `matchmaking_working_server_setup_burst_emitted`
twice, once per client, with `peer_matchmaking_session_id` different from
`own_matchmaking_session_id`, and the relay log must show per client:

```
NotifyGameSetup (real pair …)
Notify0x00E7 (working server setup burst, GID only)
NotifyJoiningPlayerInitiateConnections (working server setup burst, peer MSID)
NotifyGameStateChange (working server setup burst, GSTA=1)
```

with the inherited Leads 1–3 chain still completing unchanged afterwards.

## PASS / PARTIAL / CLEAN FAIL / VOID

- **PASS:** both clients reach the same usable pre-match lobby.
- **PARTIAL:** the burst is emitted correctly, Leads 1–3 still complete, and the joiner's behaviour after GameSetup changes in any observable way. Record the new boundary.
- **CLEAN FAIL:** the burst is emitted correctly, Leads 1–3 still complete, and the joiner behaves exactly as in `20260817-064947`. That refutes the burst as the blocking difference.
- **VOID:** wrong A/B branch or package, failed preflight, peer-gate rejection, wrong search order, stale process, crash before GameSetup, missing evidence, or instrumentation reintroduced.

**Regression signal to watch:** the burst is now the first traffic each client
sees after GameSetup. If either client goes silent *earlier* than in
`20260817-064947` — no `updateMeshConnection` at all — the burst itself is being
rejected.

## Required evidence

Player A: exact run manifest, `relay-full.log`, newest `fifa15-trace-*.jsonl`, scorecard, gameplay UDP summary and crash summary if applicable.

Player B: automatic evidence ZIP plus exact attempt manifest. Preserve any crash/WER evidence.

Do not exercise `0x00C9`, alternate GSU timing, consumables, club items, Legends, tournaments, another matchmaking scenario, or native instrumentation in this launch.
