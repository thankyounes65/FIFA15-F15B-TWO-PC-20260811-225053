# Player B runtime test — promotion notification v12

## Pair
- Player A: `thankyounes65/fifa15-relay-clean` -> `integration/test-matchmaking-promotion-notification-bundle-v12`
- Player B: `integration/test-matchmaking-b-promotion-notification-v12`

## Purpose
Provide an exact-provenance Player B appliance for the host v12 notification-combination test.

The latest v11 run reached reciprocal mesh, bidirectional UDP/3659 and the intended receiver-side post-peer GameSessionUpdated replay, yet the logical joiner still remained on the loading screen. Host v12 preserves that stack and changes one lifecycle decision only: after the joiner is promoted ACTIVE_CONNECTED, its promotion-time `NotifyPlayerJoinCompleted(joiner)` is delivered to both client streams instead of suppressing the joiner's copy as a duplicate.

Player B contains no matchmaking behavior of its own and therefore needs no protocol mutation for v12. This branch exists so the package manifest, launcher and fail-closed preflight name the exact paired host scenario rather than silently reusing v10 provenance.

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
1. Pull/checkout this exact branch.
2. Run `RUN-FIFA15-F15B.bat` normally.
3. Require package preflight PASS and wait for Player A v12 readiness.
4. Both enter FUT -> Online Single Match.
5. Player A searches first; Player B searches about three seconds later.
6. Do not cancel after pairing.
7. If the shared lobby appears, Player B readies first; verify Player A still sees B and the ready state remains coherent.
8. Then ready Player A and continue through team selection/kickoff if stable.
9. If gameplay starts, continue long enough to prove stable two-way control/synchronization.
10. If a stable blocker remains, leave it briefly for passive evidence collection, then close normally.

## Full success criterion
Both clients pair, both render the same pre-match lobby, ready/team progression succeeds, both enter the same live match, each controls its own team, and gameplay remains connected.

## Preflight failures that matter
Wrong branch/package stamp or paired-host branch, Tailscale failure, unreachable host demangler, failed forwarder, failed passive network observer, EA/LSX readiness failure, CA verification failure, or inability to reach Blaze are real prerequisites. Any such failure makes the runtime VOID.
