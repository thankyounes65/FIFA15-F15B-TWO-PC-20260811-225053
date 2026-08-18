# FIFA15 Player B Working-Server QoS Pacing + PreAuth v12

**Subsystem:** two independent things on Player A's side — (a) the *pacing* of its QoS bandwidth replies, which is what a client measures downstream from, and (b) four PreAuth fields where its login reply diverges from the working server.

**Player B branch:** `integration/test-matchmaking-working-server-setup-burst-v3`

**Player A required branch:** `thankyounes65/fifa15-relay-clean` / `integration/test-matchmaking-working-server-setup-burst-v3`

**Player A build:** `build_pairing_working_server_qos_pacing_preauth_v12.rs`, parent `build_pairing_working_server_qos_bandwidth_ack_v11.rs`

**Candidate/package:** `FIFA15-MM-WORKING-SERVER-QOS-PACING-PREAUTH-V12` / `F15B-MM-WORKING-SERVER-SETUP-BURST-V3`, peer gate TCP 48216.

**No instrumentation.** Nothing is attached to `fifa15.exe` on either machine. Player B remains a normal second client on the already-proven Tailscale/hosts/loopback/LSX/certificate/evidence stack. Retail `fifa15.exe` SHA-256 remains `3DA97D0A568475E5714E06F4871B814842A705DDC62207C2B9B66B5FC085BFFB` and no game file is modified. **Player B's wire is unchanged** — the only variables are Player A's reply timing and its PreAuth fields.

## Already Confirmed, and not under test

v10 and v11 each moved the QoS state machine forward exactly as designed (runs `20260818-154406`, `20260818-161126`):

- `qtyp=2`, the 1200-byte bandwidth probes, `/qos/firewall` and `/qos/firetype` are all requested now — none ever were before v10.
- The client's own **`NATT` reached the working server's value of 1**, up from the unmeasured 5.
- Player A's probe replies are **byte-identical to the working server's** on the wire.
- **Confirmed:** the probe reply's marker *is* the client's observed external address — the working server's client reports `EXIP.IP = 2964979879`, exactly the `0xb0ba00a7` from its QoS reply trailer.

Settled and not to be reopened: `QOSS` config, transport, MTU/delivery, connection-group identity, Legends/content identity.

## Exact hypothesis

**(a) Bandwidth reply pacing.** The client derives downstream from how fast replies arrive. The working server spreads ten 1200-byte replies over **4.624 ms** (20.8 Mbps implied) and its client then reports `DBPS 24 000 000`. Player A answered in a tight sub-millisecond burst — and its own client probes its own machine, so the spread is effectively zero. A degenerate spread yields an undefined rate and the client discards the whole bandwidth result, reporting `DBPS 0` *and* `UBPS 0`. Player A now paces at ~500 µs per reply, reproducing the captured span. **Discriminator: the clients' own `DBPS`/`UBPS` go non-zero.**

**(b) PreAuth alignment.** Four Confirmed divergences, never tested: `EEFA` not sent at all, `ESRC` empty where the working server sends `303107`, `SVER` claiming `FIFA14 Blaze 13.3.0.5.0` where the client's own `CINF` reports SDK `14.2.1.1.0`, and `CONF` carrying 3 keys instead of 5. **Discriminator: anything lobby-side.** `CIDS` and `MAID` are deliberately left alone — narrowing `CIDS` is a regression risk when login works, and `MAID` is load-bearing for per-player `MACI` agreement.

The two are bundled because their discriminators cannot be confused.

## What `REQ=2` is, and is not

An offline diff of the working server's lobby phase shows `REQ=1` and `REQ=2` arriving 1.79 s apart with **nothing exchanged in between**. `REQ=2` is **not server-triggered** — no candidate can send it; the client that owns the attribute decides locally. It stays a useful outcome signal, but it is not a thing to fix.

## Exact actions

1. Player A uses the Universal Branch Tester and selects `integration/test-matchmaking-working-server-setup-burst-v3`.
2. Player A must require `launch\VERIFY-BUILD.bat` to PASS before FIFA starts.
3. Player B uses a FRESH ZIP of this exact branch and runs `RUN-FIFA15-F15B.bat` as Administrator.
4. Require the peer gate to accept exact candidate/package `FIFA15-MM-WORKING-SERVER-QOS-PACING-PREAUTH-V12` / `F15B-MM-WORKING-SERVER-SETUP-BURST-V3`.
5. Both enter FUT → Online Single Match. **A searches first, B searches second.**
6. Do not cancel or retry after pairing.
7. If both reach the shared lobby, B readies first, then A. Continue toward kickoff only while stable.
8. If the joiner remains loading, leave the state visible briefly so evidence flushes, then close FIFA normally.

## Primary discriminator

```
                              20260818-161126 (v11)   required for v12
(a) client's own DBPS/UBPS     0 / 0                   non-zero    <- the (a) win
    completion markers         0                       10 per client
(b) PreAuth EEFA / ESRC / SVER not sent / empty / old  sent / 303107 / Blaze 14.2.1.1.0
    lobby behaviour            joiner stalls           any change is the (b) signal
```

**Player B's own capture matters**: it is the only independent record of what Player B's client actually received on UDP 17502 and how it was spaced. **Check the summary's drop counter before drawing any conclusion from an absence** — the `20260818-154406` capture was empty with 53 drops.

## PASS / PARTIAL / CLEAN FAIL / VOID

- **PASS:** both clients reach the same usable pre-match lobby, and Player A's latency indicator appears.
- **PARTIAL (a):** bandwidth goes non-zero and the latency indicator appears, but the joiner still stalls. **This completes QoS and eliminates it as a suspect** — the head lead becomes the joiner-only asymmetry.
- **PARTIAL (b):** lobby behaviour changes while bandwidth stays zero. The PreAuth alignment mattered; the pacing figure then needs tuning via Player A's env override, no rebuild.
- **CLEAN FAIL:** bandwidth stays zero with pacing confirmed on the wire and the lobby unchanged. The client is then rejecting the bandwidth result for some other reason.
- **VOID:** wrong A/B branch or package, failed preflight, peer-gate rejection, wrong search order, stale process, crash before GameSetup, missing evidence, or instrumentation reintroduced.

**Regression signal to watch — Player A's login path changes here.** `EEFA` is a tag FIFA 15's own metadata does not declare, and `SVER` changes what the server claims to be. If a client now fails to connect, or disconnects during PreAuth where it previously reached matchmaking, that is the cause and (b) must be reverted rather than iterated on.

**Honest framing.** QoS is a login-time subsystem; matchmaking is ~200 s later. v10 and v11 both landed exactly as designed and moved QoS forward without moving the lobby. **Neither change here is predicted to fix the joiner stall.** If (a) lands and the lobby is unchanged, that is a clean elimination, not a failure.

## Required evidence

Player A: exact run manifest, `relay-full.log`, newest `fifa15-trace-*.jsonl`, scorecard, gameplay UDP summary (full-packet), crash summary if applicable.

Player B: automatic evidence ZIP plus exact attempt manifest, including the wire capture and its summary. Preserve any crash/WER evidence.

Do not exercise `USID` semantics, alternate GSU timing, consumables, club items, Legends, tournaments, another matchmaking scenario, or native instrumentation in this launch.
