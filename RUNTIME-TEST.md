# FIFA15 Player B Working-Server QoS Config v9

**Subsystem:** the `QOSS` block Player A hands out at PreAuth, which configures the client's own QoS self-measurement — the latency/bandwidth probe cycle that has to complete before matchmaking's `{REQ:"2"}` step is reachable.

**Player B branch:** `integration/test-matchmaking-working-server-setup-burst-v3`

**Player A required branch:** `thankyounes65/fifa15-relay-clean` / `integration/test-matchmaking-working-server-setup-burst-v3`

**Player A build:** `build_pairing_working_server_qos_config_v9.rs`, parent `build_pairing_working_server_qos_probe_v8.rs`

**Candidate/package:** `FIFA15-MM-WORKING-SERVER-QOS-CONFIG-V9` / `F15B-MM-WORKING-SERVER-SETUP-BURST-V3`, peer gate TCP 48216.

**No instrumentation.** Nothing is attached to `fifa15.exe` on either machine. Player B remains a normal second client using the already-proven Tailscale/hosts/loopback/LSX/certificate/evidence stack. Retail `fifa15.exe` SHA-256 remains `3DA97D0A568475E5714E06F4871B814842A705DDC62207C2B9B66B5FC085BFFB` and no game file is modified. **Player B's wire is unchanged in this candidate** — the only variable is Player A's `QOSS` block and the QoS UDP responder's trace instrumentation (which changes no client-observable behaviour).

## Already Confirmed, and not under test

- Every previous wire lead through `GameSetup` and the post-`GameSetup` burst — Leads 1–7 — inherited unchanged.
- v8's entire QoS probe protocol (bandwidth/firewall/firetype routes, the UDP responder, the routable ping site, the `prpt` echo fix) is live: run `20260818-122415` proved every one of v8's own routes and responders was reachable and correctly configured.
- v8 was refuted on the discriminator that mattered: the client **never asked** for `qtyp=2`, `/qos/firewall`, or `/qos/firetype` — only `qtyp=1`, exactly twice per client, matching retail's count. v8's own responders for the other three routes were never exercised.
- Legends content identity (`fifaMatchupHash`, `OSDK_rosterVersion`, `futTeamOVR`, `futNewUser`, `fifaTeamLevel`) is identical between both clients in every run so far — refuted as a cause of the stall.

## Exact hypothesis

**The gate is one step earlier than v8 assumed: the `QOSS` config block the server hands out at PreAuth, not the routes that block advertises.**

The lossless retail capture (`packet capture/Fifa 15 Online Single Match Capture.zip`) shows:

```
retail   QOSS { ..., LNP: 10, SVID: 1161889797, TIME: 5000 }
ours     QOSS { ..., LNP: 10, SVID: 0 }                      <- TIME absent entirely
```

Tracing this to source, not guessing: the shared `QosSettings::serialize_tagged_with_service_id`
function never writes a `TIME` tag in **any** profile — a universal gap. `SVID`
is **not** uniformly zero across the relay: the `Fifa15Current` profile already
sends retail's correct `0x45410805`. The profile actually running in this
appliance (`FIFA15_PREAUTH_PROFILE=fifa14-compat`) uses a **deliberate** `0` for
that one profile's service id — a design choice made for an earlier,
unrelated experiment, not an accidental omission across the relay.

v9 changes exactly two things, both scoped to the smallest fix that tests this
without touching anything else the proven baseline depends on (the CIDS list,
`SVER` string, and everything else about the running profile are untouched):

1. `TIME: 5000` (retail's captured value) added universally.
2. The running profile's `SVID` changes from the deliberate `0` to retail's own
   `0x45410805` — the same constant `Fifa15Current` already sends, extended to
   the profile that is actually in use.

**Corroboration this failure mode is real, from a sibling engine, not FIFA15
evidence:** a FIFA14 Blaze3 private server's own PreAuth code comment (from
`evidence/fifa15 potential evidence (1).zip`, explicitly **not** a FIFA15
capture) records that a zero QoS service id is read by the client as "QoS
disabled" — it never runs a probe or reports a real address. Their fix used a
trivial non-zero value (`1`), not FIFA15's captured one; this candidate uses
FIFA15's own retail value rather than copying theirs, since that is strictly
stronger, game-specific evidence. See
`docs/FIFA14-CROSS-REFERENCE-LEADS-2026-08-18.md` on the Player A side.

**Also bundled, and explicitly NOT a second variable:** per-probe UDP trace
counters on the responder (distinguishing latency/type-2 from bandwidth/type-3
probes actually received and answered), and UDP 17502 added to both sides'
capture filters. Both are observation-only — they cannot change what the
client does — so if this run's result differs from v8's, it is attributable to
the `QOSS` change alone.

Player B's wire, boot stack and game files are **unchanged**. The only variable
is Player A's `QOSS` block and its trace instrumentation.

## Exact actions

1. Player A uses the Universal Branch Tester and selects `integration/test-matchmaking-working-server-setup-burst-v3`.
2. Player A must require `launch\VERIFY-BUILD.bat` to PASS before FIFA starts.
3. Player B uses a FRESH ZIP of this exact branch and runs `RUN-FIFA15-F15B.bat` as Administrator.
4. Require the peer gate to accept exact candidate/package `FIFA15-MM-WORKING-SERVER-QOS-CONFIG-V9` / `F15B-MM-WORKING-SERVER-SETUP-BURST-V3`.
5. Both enter FUT → Online Single Match. **A searches first, B searches second.**
6. Do not cancel or retry after pairing.
7. If both reach the shared lobby, B readies first, then A. Continue toward kickoff only while stable.
8. If the joiner remains loading, leave the state visible briefly so evidence flushes, then close FIFA normally.

## Primary discriminator

The decisive question is unchanged: does the client now request the bandwidth
phase, or reach `{REQ:"2"}`?

Player A's scorecard must show:

```
                              20260818-122415 (v8)      required now (v9)
QOSS.SVID sent as 0            2 (every PreAuth)         0
QOSS.SVID sent populated       0                         2 (once per client)
QOSS.TIME sent                 0                         2
qtyp=1 latency requests        4 (2 per client)          4 (unchanged; already matched retail)
qtyp=2 bandwidth requests      0   <- v8's gate           >0  <- the fix working
UDP probes received (any)      unobservable (no filter)  now observable
lobby REQ=2 broadcasts         0   <- the stall           >0  <- the fix working
```

Decode the relay log and trace with
`python scripts/score-matchmaking-progress.py <relay-full.log> <fifa15-trace-*.jsonl>`.

## PASS / PARTIAL / CLEAN FAIL / VOID

- **PASS:** the client requests `qtyp=2` (and ideally `/qos/firewall`/`/qos/firetype`), reports non-zero `NQOS` about itself, and both clients reach the same usable pre-match lobby.
- **PARTIAL:** the client now requests `qtyp=2` (or later routes) but the run still stops short of a usable shared lobby. Record the new boundary — that is the first movement past v8's exact stopping point.
- **CLEAN FAIL:** the scorecard confirms `QOSS.SVID` was sent populated and `TIME` was sent, the rest of the wire still scores at target, and the client **still** only ever requests `qtyp=1`. That refutes the QOSS-config hypothesis too, and means the gate is not in the config the server advertises — the next lead is whatever else differs in the PreAuth/login sequence before QoS, or whether the client's own UDP probes are even leaving the machine (the new capture-filter instrumentation should answer this either way).
- **VOID:** wrong A/B branch or package, failed preflight, peer-gate rejection, wrong search order, stale process, crash before GameSetup, missing evidence, or instrumentation reintroduced.

**Regression signal to watch:** this candidate touches the PreAuth reply, sent
to every client on every connection before login even completes. If a client
fails to connect at all, or disconnects during PreAuth/login where it
previously reached matchmaking cleanly, the `QOSS` change must be reverted
rather than iterated on — this is now the second candidate in a row to touch
login-adjacent code.

## Required evidence

Player A: exact run manifest, `relay-full.log`, newest `fifa15-trace-*.jsonl`, scorecard, gameplay UDP summary (now including UDP 17502) and crash summary if applicable.

Player B: automatic evidence ZIP plus exact attempt manifest, including the wire capture (now including UDP 17502) and its summary. Preserve any crash/WER evidence.

Do not exercise `USID` semantics, alternate GSU timing, consumables, club items, Legends, tournaments, another matchmaking scenario, or native instrumentation in this launch.
