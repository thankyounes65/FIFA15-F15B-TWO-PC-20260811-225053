# Player B runtime test — demangler + native GSU v2

## Subsystem
Online Matchmaking / FUT Online Single Match / Player B permanent loading boundary.

## Branch
`integration/test-matchmaking-b-demangler-native-v2`

## Paired host branch
`thankyounes65/fifa15-relay-clean` -> `integration/test-matchmaking-demangler-join-dedupe-v8`.

## Status
**Implemented, runtime proof pending.**

## Exact tested hypothesis
Two independently supported defects are corrected while the existing native diagnostics remain armed:

1. **DirtySDK ProtoMangle reachability.** The retail FIFA 15 client contains the EA demangler protocol on TCP/3658. The previous Player B appliance deliberately mapped `peach.online.ea.com` to `127.0.0.1` but had no 3658 service there. This branch keeps the safe role-specific loopback mapping and extends the existing loopback forwarder so 127.0.0.1:3658 reaches the paired host's ProtoMangle service. `demangler.ea.com` is also routed to the host.
2. **JoinCompleted one-shot contract.** The paired host branch removes the duplicate mesh-promotion self-JoinCompleted for the logical joiner. Player B still receives its required JoinCompleted immediately after InitiateConnections, while the later mesh completion is delivered only to the other participant.

The purpose of this run is to determine whether those changes let Player B enter the pre-match lobby and allow the session to continue end-to-end. If not, the existing exact-byte native GameSetup/JoinCompleted/GSU trace remains available to name the next boundary.

## Runtime state
- Tailscale transport remains unchanged.
- QoS/FUT loopback forwarding remains unchanged on 17502/17503.
- New forwarder port: TCP/3658 -> host TCP/3658.
- `peach.online.ea.com` remains loopback on Player B and is therefore carried through that 3658 forwarder.
- `demangler.ea.com` routes directly to the host overlay address.
- No game binary bytes are changed by this branch beyond the already-proven live CA patch required by the appliance.
- Native GSU observer remains read-only and exact-byte guarded.

## Preflight
Run only through `RUN-FIFA15-F15B.bat` on this branch.

Before FIFA is launched the BAT must prove:

- correct Git branch;
- Tailscale is connected;
- host TCP/3658 is reachable;
- the 3658/17502/17503 loopback forwarder self-test passes and all three local listeners are owned by the package worker;
- the existing Player B LSX/Blaze observer self-test passes;
- the exact-byte native observer self-test passes;
- the native evidence appender self-test passes.

Python and the `frida` Python module are required. If Frida is missing, install it with:

`python -m pip install frida`

Any failed prerequisite is **VOID**, not a matchmaking failure.

## Exact FIFA actions
1. On Player A, use the universal branch tester and select `integration/test-matchmaking-demangler-join-dedupe-v8`.
2. On Player B, run `RUN-FIFA15-F15B.bat` from this branch and allow every preflight to pass.
3. On both clients enter Ultimate Team -> Online Single Match.
4. Player A searches first.
5. About 3 seconds later, Player B searches second.
6. Do not cancel matchmaking or back out when the pair forms.
7. If a pre-match lobby appears, ready exactly once when the normal UI permits it and continue normally through team selection and kickoff.
8. If either client remains blocked, leave the stable blocker untouched for at least 30 seconds so the demangler/native traces finish.
9. If gameplay starts, continue far enough to prove both clients control their teams and gameplay packets continue in both directions. A full match may be played if stable.
10. Close FIFA normally and let the package finish evidence collection.

## Success criterion
The run is a matchmaking **PASS** only if both clients reach the same pre-match lobby, ready/team-selection state remains coherent, and both proceed into the same live match with bidirectional gameplay.

A lobby-only improvement is useful progress but is not full end-to-end confirmation.

## Evidence to collect
The normal Player B evidence ZIP should contain:

- diagnostic log;
- LSX/Blaze network observer log;
- forwarder log, including any `FORWARD_CONNECT local=127.0.0.1:3658` line if the client used the peach demangler name;
- exact native GSU JSONL/text plus stdout/stderr;
- crash evidence if generated.

The host evidence separately records every `/getPeerAddress` and `/connectionStatus` transaction in `demangler.jsonl`, including the source IP, client-reported `myIP`/`myPort`, resolved peer IP/port and session id.

## Interpretation
- Host `demangler.jsonl` receives a Player B request and resolves A, then B reaches the lobby: **demangler path materially contributed; runtime behavior still must be validated end-to-end.**
- Player B uses local 3658 (`FORWARD_CONNECT`) and host receives the request: the old loopback-with-no-listener defect is **Confirmed reached and corrected**.
- No demangler request occurs and matchmaking now works: the duplicate JoinCompleted correction is the stronger explanation for this scenario.
- No demangler request occurs and Player B still blocks: demangler is **Not Reached** for this failure; use the native GSU evidence to continue from the exact consumer boundary.
- Demangler succeeds but Player B still blocks: network fallback is no longer the first divergence; inspect the GSU trace and exact JoinCompleted counts before changing transport again.
- Wrong branch, unavailable host 3658, failed forwarder, missing Frida, failed byte guard, stale FIFA process, or failed build prerequisite: **VOID**.
