# FIFA15 Player B Working-Server Measured Pacing + Telemetry v13

**Subsystem:** two independent things on Player A's side — (a) the *pacing* of its QoS bandwidth replies, which is what a client measures downstream from, and (b) four PreAuth fields where its login reply diverges from the working server.

**Player B branch:** `integration/test-matchmaking-working-server-setup-burst-v3`

**Player A required branch:** `thankyounes65/fifa15-relay-clean` / `integration/test-matchmaking-working-server-setup-burst-v3`

**Player A build:** `build_pairing_working_server_pacing_measured_telemetry_v13.rs`, parent `build_pairing_working_server_qos_bandwidth_ack_v11.rs`

**Candidate/package:** `FIFA15-MM-WORKING-SERVER-PACING-TELEMETRY-V13` / `F15B-MM-WORKING-SERVER-SETUP-BURST-V3`, peer gate TCP 48216.

**No instrumentation.** Nothing is attached to `fifa15.exe` on either machine. Player B remains a normal second client on the already-proven Tailscale/hosts/loopback/LSX/certificate/evidence stack. Retail `fifa15.exe` SHA-256 remains `3DA97D0A568475E5714E06F4871B814842A705DDC62207C2B9B66B5FC085BFFB` and no game file is modified. **Player B's wire is unchanged** — the only variables are Player A's reply timing and its PreAuth fields.

## Already Confirmed, and not under test

v10 and v11 each moved the QoS state machine forward exactly as designed (runs `20260818-154406`, `20260818-161126`):

- `qtyp=2`, the 1200-byte bandwidth probes, `/qos/firewall` and `/qos/firetype` are all requested now — none ever were before v10.
- The client's own **`NATT` reached the working server's value of 1**, up from the unmeasured 5.
- Player A's probe replies are **byte-identical to the working server's** on the wire.
- **Confirmed:** the probe reply's marker *is* the client's observed external address — the working server's client reports `EXIP.IP = 2964979879`, exactly the `0xb0ba00a7` from its QoS reply trailer.

Settled and not to be reopened: `QOSS` config, transport, MTU/delivery, connection-group identity, Legends/content identity.

## Exact tested hypothesis

Two changes, bundled **because their discriminators cannot be confused** — (1) is scored on the trace's own spacing figure and the client's bandwidth, (2) on a request count.

### (1) Make the pacing real, and self-measuring

v12 paced with `tokio::time::sleep(500us)`. **Windows' default timer granularity is 15.6 ms**, so that call resolves to somewhere between no delay at all and a whole tick — neither of which is the captured 4.624 ms span over ten replies. v12's pacing result was therefore ruled **VOID, not refuted**: the condition it meant to create probably never existed, and Player A's capture recorded no 1200-byte packets that run so it could not be checked either.

v13 spins on `Instant` instead — the only way to hit sub-millisecond cadence on Windows without raising the system timer process-wide. Total cost is ~5 ms per client per session, paid once at login.

It also records the **actual elapsed time** since the previous bandwidth reply on every answer (`spacing_us`), so the next run proves or disproves the pacing from the relay's own trace rather than from a capture that has now failed twice.

### (2) Stop the telemetry flood

Run `20260818-164103` answered **3743 `SubmitTelemetryReport` calls**. The working server's entire session contains **zero**. The cause is a Confirmed divergence in the block that configures it:

```
working server  TELE {ANON: 0, DISA: '1',           NOOK: '',            PORT: 9988, SDLY: 0,     SESS: '', SKEY: ''}
ours            TELE {ANON: 1, DISA: 'GB,US,CA,MX', NOOK: 'GB,US,CA,MX', PORT: 0,    SDLY: 15000, SESS: 'fifa15-local-telemetry', SKEY: '...'}
```

`DISA: '1'` reads as *telemetry disabled*. A country list is a filter the client is not in, so telemetry stayed **on**. Those 3743 request/response round-trips share the one TCP connection that also carries the lobby state machine — a plausible way to delay or starve it, and regardless of that, a large behavioural divergence from the only configuration known to complete a match.

Both writers move together: `PostAuth` and `getTelemetryServer` answer with the same block in the working server, and telling the client two different things would be worse than either value.

### Closed this round: the completion markers

The 8-byte markers are a **red herring** and must stop being scored. Player B *does* send its ten — to `54.142.91.100`, which is our `qosip` read big-endian. The working server's client does exactly the same, sending them to `10.223.214.178` while its real server is `178.214.223.10`. **Both sets are lost**, and the working server reaches `DBPS 24000000` / `UBPS 123456789` without ever receiving one.

## What `REQ=2` is, and is not

An offline diff of the working server's lobby phase shows `REQ=1` and `REQ=2` arriving 1.79 s apart with **nothing exchanged in between**. `REQ=2` is **not server-triggered** — no candidate can send it; the client that owns the attribute decides locally. It stays a useful outcome signal, but it is not a thing to fix.

## Exact actions

1. Player A uses the Universal Branch Tester and selects `integration/test-matchmaking-working-server-setup-burst-v3`.
2. Player A must require `launch\VERIFY-BUILD.bat` to PASS before FIFA starts.
3. Player B uses a FRESH ZIP of this exact branch and runs `RUN-FIFA15-F15B.bat` as Administrator.
4. Require the peer gate to accept exact candidate/package `FIFA15-MM-WORKING-SERVER-PACING-TELEMETRY-V13` / `F15B-MM-WORKING-SERVER-SETUP-BURST-V3`.
5. Both enter FUT → Online Single Match. **A searches first, B searches second.**
6. Do not cancel or retry after pairing.
7. If both reach the shared lobby, B readies first, then A. Continue toward kickoff only while stable.
8. If the joiner remains loading, leave the state visible briefly so evidence flushes, then close FIFA normally.

## Primary discriminator

```
                              20260818-164103 (v12)   required for v13
(1) trace spacing_us           absent (no field)       ~500 on bandwidth replies
    client's own DBPS/UBPS     0 / 0                   non-zero
(2) SubmitTelemetryReport      3743                    near 0
    TELE DISA sent             'GB,US,CA,MX'           '1'
    lobby behaviour            joiner stalls           any change is the (2) signal
```

**Player B's own capture matters**: it is the only independent record of what Player B's client actually received on UDP 17502 and how it was spaced. **Check the summary's drop counter before drawing any conclusion from an absence** — the `20260818-154406` capture was empty with 53 drops.

## PASS / PARTIAL / CLEAN FAIL / VOID

- **PASS:** both clients reach the same usable pre-match lobby, and Player A's latency indicator appears.
- **PARTIAL (1):** `spacing_us` confirms real pacing and bandwidth goes non-zero, but the joiner still stalls. **That completes QoS and eliminates it** — the head lead becomes the joiner-only asymmetry.
- **PARTIAL (2):** the telemetry flood stops and lobby behaviour changes while bandwidth stays zero. Then the flood mattered and the pacing figure needs tuning via the env override, no rebuild.
- **CLEAN FAIL:** `spacing_us` confirms ~500 µs pacing, telemetry is quiet, and both bandwidth and the lobby are unchanged. Then the reply *timing* is not what the client rejects, and the remaining candidate is the marker control arm (`FIFA15_QOS_PROBE_LITERAL_MARKER=1`) — after which QoS should be set aside entirely.
- **VOID:** wrong A/B branch or package, failed preflight, peer-gate rejection, wrong search order, stale process, crash before GameSetup, missing evidence, or instrumentation reintroduced.

**Regression signal to watch.** Disabling telemetry changes what the client does on the shared connection; if a client now disconnects mid-lobby where it previously stayed up, revert (2). The spin-wait blocks the responder task for ~5 ms per client; if QoS probes start being dropped or answered late, lower `FIFA15_QOS_BANDWIDTH_REPLY_SPACING_US`.

**Honest framing.** QoS is a login-time subsystem; matchmaking is ~200 s later. v10 and v11 both landed exactly as designed and moved QoS forward without moving the lobby. **Neither change here is predicted to fix the joiner stall.** If (a) lands and the lobby is unchanged, that is a clean elimination, not a failure.

## Required evidence

Player A: exact run manifest, `relay-full.log`, newest `fifa15-trace-*.jsonl`, scorecard, gameplay UDP summary (full-packet), crash summary if applicable.

Player B: automatic evidence ZIP plus exact attempt manifest, including the wire capture and its summary. Preserve any crash/WER evidence.

Do not exercise `USID` semantics, alternate GSU timing, consumables, club items, Legends, tournaments, another matchmaking scenario, or native instrumentation in this launch.
