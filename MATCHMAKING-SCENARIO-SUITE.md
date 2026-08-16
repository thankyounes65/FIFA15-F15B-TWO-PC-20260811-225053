# Player B - FIFA15 four-scenario matchmaking suite

Each runtime branch carries one `MATCHMAKING-SCENARIO.json`. `RUN-FIFA15-F15B.bat` verifies the exact B branch, fixed-v16 ancestry, expected Player A branch/build, candidate ID and package token before connecting to Player A's scenario gate. The proven v18/fixed-v16 B boot, Tailscale, forwarder, observer, native attestation, diagnostic runtime and evidence collector are inherited unchanged.

Evidence is copied after every attempt into `runs/matchmaking-scenarios/player-b/scenario-N-slug/<timestamp>/`. Selection is bounded by the invocation start time so a VOID/preflight failure cannot silently inherit an older run. No automatic GitHub upload/publish occurs.

After the desired four runs, execute `ZIP-MATCHMAKING-SCENARIOS.bat` and manually upload the resulting `PLAYER-B-MATCHMAKING-SCENARIOS-*.zip` alongside Player A's ZIP for Codex/offline analysis.
