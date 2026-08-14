# Player B runtime test — identity/session v4

## Pair
- Player A: `thankyounes65/fifa15-relay-clean` -> `integration/test-matchmaking-identity-session-coherence-v10`
- Player B: `integration/test-matchmaking-b-identity-session-v4`

## Purpose
Validate FUT Online Single Match end-to-end against the host v10 GameManager PlayerID and GameSessionUpdated ordering correction.

The v9 run proved A no longer crashes, raw UDP/3659 is strongly bidirectional, and B can still remain on the loading screen. Host v10 therefore fixes the two concrete above-transport defects from that run: one coherent GameManager PlayerID namespace and deferring the host's peer GameSessionUpdated until B is genuinely ACTIVE_CONNECTED from client-reported mesh state.

Player B v4 is appliance/provenance only. It does not fabricate PlayerID or session data locally.

## Safety
V4 uses **no in-process FIFA instrumentation**. No Frida, Stalker, native GSU tracer, or native observer is attached. Historical native files may remain for archaeology, but the launcher does not start them and package preflight rejects activation.

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
1. Pull/checkout this exact branch.
2. Run `RUN-FIFA15-F15B.bat` normally.
3. Let preflight finish and wait for Player A v10 readiness.
4. Both enter FUT -> Online Single Match.
5. Player A searches first; Player B searches about three seconds later.
6. Do not cancel after pairing.
7. If the shared lobby appears, ready normally once and continue through team selection/kickoff.
8. If gameplay starts, continue long enough to prove stable two-way control/synchronization.
9. If a stable blocker remains, leave it for about 30 seconds, then close normally for passive evidence collection.

## Full success criterion
Both clients pair, both render the same pre-match lobby, ready/team progression succeeds, both enter the same live match, each controls its own team, and gameplay remains connected.

## Preflight failures that matter
Wrong branch/package stamp, Tailscale failure, unreachable host demangler, failed forwarder, failed passive network observer, EA/LSX readiness failure, CA verification failure, or inability to reach Blaze are real prerequisites. Frida, native byte guards, retained dumps and Node are not v4 prerequisites.
