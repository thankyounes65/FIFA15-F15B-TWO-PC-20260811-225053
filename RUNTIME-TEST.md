# FIFA15 Player B Working-Server QoS Bandwidth-Ack v11

**Subsystem:** the QoS probe reply payload — the 30 bytes Player A's server sends back for every UDP probe, which the client needs before it will move on to the bandwidth phase.

**Player B branch:** `integration/test-matchmaking-working-server-setup-burst-v3`

**Player A required branch:** `thankyounes65/fifa15-relay-clean` / `integration/test-matchmaking-working-server-setup-burst-v3`

**Player A build:** `build_pairing_working_server_qos_bandwidth_ack_v11.rs`, parent `build_pairing_working_server_qos_reply_v10.rs`

**Candidate/package:** `FIFA15-MM-WORKING-SERVER-QOS-BW-ACK-V11` / `F15B-MM-WORKING-SERVER-SETUP-BURST-V3`, peer gate TCP 48216.

**No instrumentation.** Nothing is attached to `fifa15.exe` on either machine. Player B remains a normal second client using the already-proven Tailscale/hosts/loopback/LSX/certificate/evidence stack. Retail `fifa15.exe` SHA-256 remains `3DA97D0A568475E5714E06F4871B814842A705DDC62207C2B9B66B5FC085BFFB` and no game file is modified. **Player B's wire is unchanged in this candidate** — the only variable is the bytes Player A puts in its QoS replies.

## Already Confirmed, and not under test

Run `20260818-144512` (v9) settled a lot, and all of it is inherited:

- **Lead 10 / `QOSS` is Refuted.** `SVID: 1161889797` and `TIME: 5000` both landed on every PreAuth and the clients still never requested `qtyp=2`. Do not reopen it.
- **Probes flow and are answered: 150 received, 150 answered, 0 capture drops.** Transport is not the problem, on either machine.
- The latency phase completes its exact `LNP: 10` per client.
- `qtyp=1` is requested twice per client — the same count retail issues.
- No login regression: 2 clean logins, 0 errors, `GameSetup` fired, matchmaking paired.
- Legends / content identity: Refuted.

## Exact hypothesis

v9's per-probe counters — bundled precisely so this would be visible — showed the client **looping in the type-3 probe phase for 49 seconds**, 60–70 probes per client where retail sends 10. Retail's entire QoS sequence takes **451 ms**.

Byte comparison against the lossless capture gives retail's reply rule, which is uniform across **every** probe:

```
reply = [first 20 request bytes echoed]
      + [u32 marker][u16 sender's port][u32 zero]
      + zero padding out to max(30, request length)

  20-byte probe (type 2 AND type 3) -> marker 0xb0ba00a7, reply 30 B
  1200-byte bandwidth probe         -> marker 0x075bcd15, reply 1200 B
```

`0x075bcd15` is `123456789` — exactly the `UBPS` every captured client reports about itself. The server **hands** the client that figure and the client repeats it back. That corrects v7's account, which treated it as a constant the server invents about a peer.

### Five defects fixed

| # | defect | exercised before? |
| --- | --- | --- |
| 1 | latency trailer carried a counter and payload length, not marker and port | yes |
| 2 | **a 20-byte type-3 probe got a bare 20-byte echo, no trailer at all** | yes — **this stalls the run** |
| 3 | `/qos/firetype` missing the XML declaration *and* the outer `<firetype>` wrapper | never |
| 4 | `/qos/firewall` missing the XML declaration | never |
| 5 | `qosip` big-endian; retail is little-endian | yes |

Defects 3 and 4 were latent in routes written but never once requested. They were found by pre-verifying the never-exercised paths against the capture rather than waiting for a future run to expose them. Response headers now also carry `charset=utf-8` and `Cache-Control: no-store`, and the 8-byte completion marker the client sends ×10 at the end of the bandwidth phase is recorded rather than dropped (retail never replies to it, and neither do we).

### What is Inference, and how it is hedged

The `0xb0ba00a7` marker is byte-identical across the whole captured session, so it is **not** a timestamp. Big-endian it reads `176.186.0.167` — a plausible public address — sitting directly beside a field that is unambiguously the client's port. So it most likely means "the address I see you at". That reading is an **Inference**, not Confirmed: the value is never echoed anywhere observable, and the protocol's XML uses the opposite byte order for addresses.

Player A therefore implements the **rule**, and keeps retail's literal constant available as a control arm (`FIFA15_QOS_PROBE_LITERAL_MARKER=1`) that needs no rebuild. The rule is validated by a unit test that replays retail's exact captured probe and asserts our output matches retail's captured reply **byte for byte**.

## Exact actions

1. Player A uses the Universal Branch Tester and selects `integration/test-matchmaking-working-server-setup-burst-v3`.
2. Player A must require `launch\VERIFY-BUILD.bat` to PASS before FIFA starts.
3. Player B uses a FRESH ZIP of this exact branch and runs `RUN-FIFA15-F15B.bat` as Administrator.
4. Require the peer gate to accept exact candidate/package `FIFA15-MM-WORKING-SERVER-QOS-BW-ACK-V11` / `F15B-MM-WORKING-SERVER-SETUP-BURST-V3`.
5. Both enter FUT → Online Single Match. **A searches first, B searches second.**
6. Do not cancel or retry after pairing.
7. If both reach the shared lobby, B readies first, then A. Continue toward kickoff only while stable.
8. If the joiner remains loading, leave the state visible briefly so evidence flushes, then close FIFA normally.

## Primary discriminator

```
                                20260818-144512 (v9)   required for v10
replies of 20 bytes              many (the defect)      0
replies of 30 bytes              latency only           every 20-byte probe
type-3 probes per client         60-70 (looping)        ~10 (then it moves on)
qtyp=2 bandwidth requests        0                      >0
/qos/firewall, /qos/firetype     0                      >0
bandwidth completion markers     0                      10 per client
client's own NQOS                DBPS 0 / NATT 5 / UBPS 0   non-zero
lobby REQ=2 broadcasts           0                      >0
```

**Player B's own capture matters here**: it is the only place that shows what Player B's client actually sent and received on UDP 17502, independently of Player A's own account of what it answered.

## PASS / PARTIAL / CLEAN FAIL / VOID

- **PASS:** both clients reach the same usable pre-match lobby.
- **PARTIAL:** the QoS sequence completes — `qtyp=2`, firewall, firetype, completion markers and a non-zero `NQOS` — but `REQ=2` still does not appear. **This is a valuable outcome, not a failure:** it would be the first complete QoS measurement this appliance has produced, and it eliminates QoS as a suspect instead of leaving it merely suspected.
- **CLEAN FAIL:** replies are confirmed 30 bytes and correctly shaped, and the client **still** loops in the type-3 phase. That means the marker's value matters and our reading of it is wrong; the immediate next step is the control arm, which needs no new build.
- **VOID:** wrong A/B branch or package, failed preflight, peer-gate rejection, wrong search order, stale process, crash before GameSetup, missing evidence, or instrumentation reintroduced.

**Regression signal to watch:** this changes bytes on a path both clients already exercise successfully today — the latency reply — and changes `qosip` on the reply that precedes every probe. If probes stop arriving altogether, or a client stops requesting `qtyp=1`, something that previously worked has broken and the change must be reverted rather than iterated on.

**Honest framing.** QoS is a **login-time** subsystem: retail runs it once, at t≈59 s, and matchmaking is ~200 s later. Our client already abandons QoS and proceeds into matchmaking anyway. So this candidate fixes five Confirmed byte-level defects and should produce a real `NQOS` for the first time — but whether that is what `REQ=2` was waiting on is the experiment, **not** the prediction.

## Required evidence

Player A: exact run manifest, `relay-full.log`, newest `fifa15-trace-*.jsonl`, scorecard, gameplay UDP summary (includes UDP 17502) and crash summary if applicable.

Player B: automatic evidence ZIP plus exact attempt manifest, including the wire capture (includes UDP 17502) and its summary. Preserve any crash/WER evidence. If the summary reports pktmon drops, absence of a frame proves nothing.

Do not exercise `USID` semantics, alternate GSU timing, consumables, club items, Legends, tournaments, another matchmaking scenario, or native instrumentation in this launch.
