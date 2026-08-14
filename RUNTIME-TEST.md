# Player B runtime test — demangler no-Frida v3

## Pair
- Player A: `thankyounes65/fifa15-relay-clean` -> `integration/test-matchmaking-demangler-join-dedupe-v9`
- Player B: `integration/test-matchmaking-b-demangler-no-frida-v3`

## Purpose
Validate FUT Online Single Match end-to-end after removing the in-process native diagnostic mechanism implicated in Player A's previous crash.

The previous run reached pairing/native GameSessionUpdated on A and DirtySDK ProtoMangle on B, then A died immediately after the generated-code branch trace began. B subsequently reported lost opponent. This run therefore changes the diagnostic variable, not the retained matchmaking protocol candidate.

## V3 safety rule
**No in-process Frida, Stalker, native GSU tracer, or native observer is attached to Player B's FIFA process.** Player A v9 follows the same rule.

Historical `guest-native-gsu-*` files may remain in the repository, but `RUN-FIFA15-F15B.bat` does not start them and package preflight rejects a launcher that does.

## Retained runtime behavior
- Tailscale bootstrap and exact restoration;
- host readiness gate;
- local LSX/EA readiness;
- CA write/readback launcher;
- loopback forwarding for ProtoMangle 3658, QoS 17502 and FUT 17503;
- host-side demangler registration/readiness;
- passive LSX/Blaze/network observation;
- automatic evidence collection.

## Run
1. Pull/checkout this exact Player B branch.
2. Run `RUN-FIFA15-F15B.bat` normally.
3. Let preflight complete; it will wait for Player A's v9 demangler/readiness service.
4. On FIFA, enter Ultimate Team -> Online Single Match.
5. Player A searches first; Player B searches about three seconds later.
6. If both reach the pre-match lobby, ready normally and continue into the match.
7. If a blocker appears, leave it stable for about 30 seconds, then close normally so passive evidence is collected.

## Full success criterion
Both clients pair, both enter the same pre-match lobby, normal ready/team progression succeeds, both enter the same live match, and the connection remains stable with bidirectional gameplay.

## Preflight failures that matter
Wrong branch/package stamp, Tailscale failure, unreachable host demangler, failed forwarder, failed passive network observer, EA/LSX readiness failure, CA verification failure, or inability to reach Blaze are real prerequisites and stop the run.

Frida availability, native byte guards, retained dumps, Node, native tracer startup and native evidence appending are intentionally **not** prerequisites in v3.
