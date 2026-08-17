# FIFA15 Player B Working-Server PID Promotion v2

**Subsystem:** FUT Online Single Match matchmaking — post-GameSetup mesh identity and promotion lifecycle.

**Player B branch:** `integration/test-matchmaking-working-server-pid-promotion-v2`

**Player A required branch:** `thankyounes65/fifa15-relay-clean` / `integration/test-matchmaking-working-server-pid-promotion-v2`

**Player A build:** `build_pairing_working_server_pid_promotion_v2.rs`

**Candidate/package:** `FIFA15-MM-WORKING-SERVER-PID-PROMOTION-V2` / `F15B-MM-WORKING-SERVER-PID-PROMOTION-V2`.

**No instrumentation.** Nothing is attached to `fifa15.exe` on either machine. Player B remains a normal second client using the already-proven Tailscale/hosts/loopback/LSX/certificate/evidence stack. Retail `fifa15.exe` SHA-256 remains `3DA97D0A568475E5714E06F4871B814842A705DDC62207C2B9B66B5FC085BFFB` and no game file is modified.

## Exact hypothesis

The preserved parity attempt `20260817-033118` advanced through GameSetup, four mesh requests, host Finalize, client `GSTA=130`, sustained telemetry and bidirectional UDP, but every mesh request resolved `target_user_id=unknown` because authenticated self `CGID/SCG` still used fabricated `1515100001/2` while parity GameSetup correctly published target `CONG/UGID/TCG` using full-width player PID.

The same run also sent an inherited `NotifyPlayerJoinCompleted (donor host setup complete)` before Finalize, while the real working FIFA 15 capture starts both players at `STAT=2` and sends both players' `STAT=4` plus both `JoinCompleted` notifications only after the client requests `GSTA=130`.

Player A v2 therefore changes one causal lifecycle chain:

1. full-width PID is the connection-group id on authenticated CGID/SCG and GameSetup CONG/UGID/TCG;
2. PID TCG resolves to the real paired user so UpdateMeshConnection enters mesh state;
3. neither host nor joiner is completed during setup;
4. promotion requires both a genuine cross-player CONNECTED edge and client-owned `GSTA=130`;
5. the release bundle is one-shot and ordered `GSTA130 -> STAT4(A/B) -> JoinCompleted(A/B)`.

The documented remaining working-server notification differences (“Lead 4”) are deliberately **not** enabled in this run.

## Exact actions

1. Player A uses the Universal Branch Tester and selects `integration/test-matchmaking-working-server-pid-promotion-v2`.
2. Player A must require `launch\VERIFY-BUILD.bat` to PASS before FIFA starts.
3. Player B uses this exact branch/package and runs `RUN-FIFA15-F15B.bat` as Administrator.
4. Require the peer gate to accept exact candidate/package `FIFA15-MM-WORKING-SERVER-PID-PROMOTION-V2` / `F15B-MM-WORKING-SERVER-PID-PROMOTION-V2`.
5. Both enter FUT -> Online Single Match. **A searches first, B searches second.**
6. Do not cancel or retry after pairing.
7. If both reach the shared lobby, B readies first, then A. Continue toward kickoff only while stable.
8. If the joiner remains loading, leave the state visible briefly so evidence flushes, then close FIFA normally.

## Primary discriminator

The run should produce this exact chain in Player A evidence:

`TCG=<peer PID> -> target_user_id=<peer PID> -> matchmaking_mesh_link_recorded -> client GSTA130 -> matchmaking_working_server_pre_game_released -> matchmaking_working_server_promotion_bundle`

and the relay should show two promotion-time `NotifyGamePlayerStateChange`/STAT4 notifications plus two `NotifyPlayerJoinCompleted` notifications, with **no** `donor host setup complete` notification.

## PASS / PARTIAL / FAIL

- **PASS for Leads 1–3:** PID mesh targets resolve, a real peer edge is recorded, the GSTA130 gate releases, both players receive STAT4 + JoinCompleted, and both clients reach the same usable pre-match lobby.
- **PARTIAL:** the full Leads 1–3 chain is proven but the lobby still fails. Freeze those findings as Confirmed and move investigation to documented Lead 4 / the first later divergence; do not reopen transport or connection-group identity.
- **CLEAN FAIL:** exact v2 identity and promotion bundle execute without transport regression but the old loading boundary remains. Leads 1–3 are then fixed-but-not-sufficient.
- **VOID:** wrong A/B branch or package, failed preflight, peer-gate rejection, wrong search order, stale process, crash before relevant GameSetup/mesh/GSTA boundary, missing evidence, or instrumentation reintroduced.

## Required evidence

Player A: exact run manifest, `relay-full.log`, newest `fifa15-trace-*.jsonl`, scorecard, gameplay UDP summary and crash summary if applicable.

Player B: automatic evidence ZIP plus exact attempt manifest. Preserve any crash/WER evidence.

Do not exercise consumables, club items, Legends, tournaments, another matchmaking scenario, Lead 4 notification experiments, alternate GSU timing, or native instrumentation in this launch.
