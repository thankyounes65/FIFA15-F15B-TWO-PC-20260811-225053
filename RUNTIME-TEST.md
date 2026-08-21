# FIFA15 Player B — QoS State Parity v1

## Runtime contract

- Player B branch: `integration/test-matchmaking-qos-state-parity-v1`
- Player A repo/branch: `thankyounes65/fifa15-relay-clean` / `integration/test-matchmaking-qos-state-parity-v1`
- Player A build: `build_pairing_working_server_qos_state_parity_v15b.rs`
- Candidate: `FIFA15-MM-QOS-STATE-PARITY-V1`
- Package: `F15B-MM-QOS-STATE-PARITY-V1`
- Peer gate: TCP `48216`
- Runtime baseline: `77e527180a6cf3810e5eafc4be1cb40230a0fd99`
- Instrumentation: **none**. Nothing attaches to `fifa15.exe`.

Player B changes no matchmaking wire behavior. It reuses the existing verified
boot/connect/Tailscale/loopback-forwarder/game-file verification/pktmon capture
stack. Only Player A changes the relay's QoS state ownership.

## Hypothesis

FIFA authors `DBPS`/`UBPS` in `UserSessions.UpdateNetworkInfo.QDAT`. The prior
relay kept address/NATT but discarded those two measured values, then later sent
zero or old capture constants in self/peer/GAME QoS documents. The candidate
retains the values per exact user and reuses them where the working service does.

No `qosip`, UDP/HTTP QoS choreography, NATT, endpoint, REQ, or native pregame
change is part of this test.

## Exact actions

1. Player A fast-forwards to the exact A branch above, builds, and runs
   `launch\WAIT-PEER-MATCHMAKING-QOS-STATE-PARITY-V1.bat`.
2. Player B fast-forwards this branch and runs `RUN-FIFA15-F15B.bat` as Administrator.
3. Require the gate to accept exactly `FIFA15-MM-QOS-STATE-PARITY-V1` /
   `F15B-MM-QOS-STATE-PARITY-V1` before matchmaking.
4. Both enter FUT -> Online Single Match. **A searches first; B searches second.**
5. Do not cancel or retry after pairing.
6. If the shared lobby appears, B readies first, then A; continue only while stable.
7. Otherwise leave the stalled state visible briefly so evidence flushes, then close FIFA normally.
8. Preserve the automatic Player B evidence ZIP and A-side runtime evidence.

## Primary discriminator

REQ2 is secondary only. Score this run in order:

1. Player A observes nonzero client QDAT via `matchmaking_qos_measurement_observed` for the correct user(s).
2. Those values are republished instead of being discarded/zeroed.
3. Player B's gameplay UDP changes from the known failing tiny-packet profile to
   application traffic: >=150-byte payload is the first movement; >=400-byte
   host->joiner packets are the strongest match to the working reference.
4. Record REQ2/shared-lobby progress only after the above.

## PASS / PARTIAL / CLEAN FAIL / VOID

- **PASS:** exact candidate ran, measured QDAT propagated, native/application
  traffic appears, and both clients reach the same usable pre-match lobby.
- **PARTIAL:** measured state lands and the traffic/stall boundary moves but no
  usable lobby. Preserve the new first divergence.
- **CLEAN FAIL:** exact candidate ran; nonzero measured QDAT was observed and
  republished; low-level mesh/UDP still forms; both-seat captures remain devoid
  of >=150-byte application payload. This refutes QoS state propagation as the
  immediate native-activation blocker.
- **VOID:** wrong branch/package, failed preflight or gate, wrong search order,
  stale process, missing/drop-invalid evidence, crash before the hypothesis is
  reached, or instrumentation attached to FIFA.

## Required Player B evidence

The dedicated runner automatically records the attempt manifest and runs the
existing filtered pktmon capture/collector. Preserve:

- automatic evidence ZIP;
- attempt `RUN-MANIFEST.txt`;
- `.pcapng`/ETL and capture/drop summary;
- crash/WER evidence if present.

Do not exercise a second matchmaking attempt, alternate ordering, other FUT
systems, REQ/native forcing, or native instrumentation in this launch.
