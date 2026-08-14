# Player B runtime test — native GSU observer v1

## Subsystem
Online Matchmaking / FUT Online Single Match / Player B permanent loading boundary.

## Branch
`integration/test-matchmaking-b-native-gsu-v1`

## Paired host branch
`thankyounes65/fifa15-relay-clean` -> `integration/test-matchmaking-gsu-bilateral-trace-v7`.

## Status
**Implemented, runtime proof pending.**

## Purpose
Player B previously showed the permanent stadium/loading background while the host relay proved that B still emitted mesh reports and SetPlayerAttributes `REQ=1`. The prior B network observer proved process/socket reachability but did not observe FIFA's native GameSetup/ConnApi/GameSessionUpdated consumer.

This branch changes no Tailscale, forwarder, FUT, LSX, Blaze, game-file, or matchmaking protocol behavior. It adds a read-only native observer only.

## Native evidence collected
The observer uses the exact RVAs and runtime-decrypted instruction preimages already proven on Player A. `PLAYER-B-KNOWN-GOOD.json` pins the same `fifa15.exe` SHA-256, and all 18 probes fail closed on byte mismatch.

It records:

- GameSetup dispatcher reachability;
- native roster/player registration completion;
- JoinCompleted game/player lookup and callback reachability;
- GameSessionUpdated entry and game lookup;
- local-index gate;
- native network predicate at RVA `0x47BC5B7`;
- downstream local-player/game-flag/callback sites;
- a bounded 150 ms post-predicate Stalker trace if the predicate site is reached.

The observer does not modify registers, memory, branch conditions, game state, lifecycle state, or network state.

## Preflight
Run only through `RUN-FIFA15-F15B.bat` on this branch. It must pass both the existing network-observer self-test and the new native-observer self-test before FIFA is launched.

Python and the `frida` Python module are required for this diagnostic branch. If Frida is missing, the launcher stops before FIFA and prints:

`python -m pip install frida`

A missing prerequisite is **VOID**, not a matchmaking failure.

## Exact actions
1. Start `RUN-FIFA15-F15B.bat` and let all preflights pass.
2. Enter FUT -> Online Single Match.
3. Player A searches first on the paired host v7 branch.
4. Wait roughly 3 seconds, then Player B searches second.
5. If Player B reaches the same permanent loading screen, leave it untouched for at least 30 seconds.
6. Use ready once only if FIFA exposes the same action as the previous run.
7. If both clients progress, continue normally into team select/gameplay; otherwise stop at the stable blocker.
8. Close FIFA normally and allow the package to create the newest `FIFA15-F15B-EVIDENCE-*.zip`.

## Required evidence
The ZIP is automatically updated with the exact stamped native observer JSONL/text plus redirected stdout/stderr and a native evidence manifest. This makes observer/probe failure distinguishable from a genuine native path not being reached.

## Interpretation
- no GameSetup dispatcher while host sent GameSetup -> delivery/dispatch boundary;
- GameSetup reached but player registration/JoinCompleted lookup fails -> roster/identity boundary;
- JoinCompleted completes but GSU never runs -> native session scheduling boundary;
- GSU runs with `network_predicate=0` while A reports 1 -> B ConnApi/network-map/discovery coherence is primary; demangler/UpdateNetworkInfo work becomes justified;
- both report predicate 1 but diverge immediately after -> reverse the exact branch/field before any bypass;
- both take the same native path while only B stays blank -> move downstream to team-select/UI state rather than transport.
