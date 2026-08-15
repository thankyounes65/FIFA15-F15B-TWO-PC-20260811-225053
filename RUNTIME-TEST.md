# Player B runtime test — joiner result v13

## Pair
- Player A: `thankyounes65/fifa15-relay-clean` -> `integration/test-matchmaking-joiner-result-v13`
- Player B: `integration/test-matchmaking-b-joiner-result-v13`

## Purpose
Provide an exact-provenance Player B appliance for the isolated FIFA 15 recipient-role matchmaking-result test.

The logical joiner has repeatedly received a technically live GameManager session — GameSetup, InitiateConnections, JoinCompleted, mesh/UDP and ready traffic — while remaining on the loading screen and never reaching the later lobby-side `/squad/list` and `/squad/0` requests that Player A reaches.

Retail FIFA 15 distinguishes `SUCCESS_CREATED_GAME=0` from `SUCCESS_JOINED_NEW_GAME=1`. The relay historically sent `REAS.RSLT=0` to both recipients. Host v13 changes only that field by recipient role:

- Player A / logical host: `REAS.RSLT=0` (`SUCCESS_CREATED_GAME`)
- Player B / logical joiner: `REAS.RSLT=1` (`SUCCESS_JOINED_NEW_GAME`)

The retained v12 bilateral promotion-time `NotifyPlayerJoinCompleted(joiner)` and v11 post-peer GameSessionUpdated replay remain active.

Player B contains no matchmaking protocol implementation of its own. This branch changes package provenance/instructions only; Tailscale, LSX, loopback forwarding, passive observation and evidence collection are inherited unchanged from the v12 appliance.

## Safety
No in-process FIFA instrumentation. No Frida, Stalker, native GSU tracer, or native observer is attached. Historical native files may remain for archaeology, but the launcher does not start them and package preflight rejects activation.

## Retained B behavior
- Tailscale bootstrap and exact restoration;
- host readiness gate;
- local LSX/EA readiness;
- CA write/readback launcher;
- loopback forwarding for ProtoMangle 3658, QoS 17502 and FUT 17503;
- host-side demangler registration/readiness;
- passive LSX/Blaze/network observation;
- automatic evidence collection.

## Run
1. Use a fresh checkout or fresh GitHub ZIP of this exact branch.
2. Run `RUN-FIFA15-F15B.bat` normally.
3. Require package preflight PASS and wait for Player A v13 readiness.
4. Both enter FUT -> Online Single Match.
5. Player A searches first; Player B searches second using the recent normal timing.
6. Do not cancel after pairing.
7. The v13 wire criterion for this machine is **REAS.RSLT=1 / SUCCESS_JOINED_NEW_GAME** in Player B's GameSetup.
8. If the shared lobby appears, Player B readies first; verify Player A still sees B and ready state remains coherent.
9. Then ready Player A and continue through team selection/kickoff if stable.
10. If gameplay starts, continue long enough to prove stable two-way control/synchronization.
11. If a stable blocker remains, leave it briefly for passive evidence collection, then close normally.

## Full success criterion
Exact v13 provenance, Player B receives the joiner result `REAS.RSLT=1`, both clients pair and render the same pre-match lobby, ready/team progression succeeds, both enter the same live match, each controls its own team, and gameplay remains connected.

## Clean failure interpretation
If exact v13 provenance and `REAS.RSLT=1` are proven, reciprocal mesh/UDP remains healthy and Player B still stays on the same loading boundary, then recipient-specific RSLT is **Refuted as sufficient**. Return to the documented FIFA15 schema/ownership leads — foreign `REAS.TTM/USID`, retail GSU `GID+NPSI`, then player-session/local-ownership identity — rather than another GSU timing experiment.

## Preflight failures that matter
Wrong branch/package stamp or paired-host branch, stale v12 provenance, Tailscale failure, unreachable host demangler, failed forwarder, failed passive network observer, EA/LSX readiness failure, CA verification failure, or inability to reach Blaze are real prerequisites. Any such failure makes the runtime VOID.
