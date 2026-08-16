FIFA15 Player-B matchmaking scenario suite

Run: RUN-FIFA15-F15B.bat
Choose the SAME scenario number that Player A selected from the universal branch tester.

1 = one JoinCompleted(A) to B after B GameSetup and before 0x16
2 = SCG==TCG registers only; first real peer edge triggers promotion
3 = keep first B GSU and suppress the second peer-edge replay
4 = exactly one B GSU, moved to the first real peer edge

The fixed v16/v18 Player-B boot, network observer, native attestation and diagnostic runtime are reused. The wrapper renders the proven v18 BAT with only candidate/attestation labels changed for the selected A scenario.

Each attempt now also keeps its rendered B launcher, copied scenario contract,
hashes, exact B revision when available, and a PLAYER-B-OBSERVATION.txt template.
The network observer proves connectivity/reachability only; the native map is
static attestation and does not prove a FIFA callback ran. The exact Player-A
relay trace remains the wire/callback evidence source for B's GameManager path.

Evidence stays local. Each run is archived under:
  runs\matchmaking-scenarios\player-b\scenario-<n>-<slug>\<timestamp>\

After all four runs, zip runs\matchmaking-scenarios\player-b for offline analysis. No automatic GitHub evidence upload is performed.
See PLAYER-B-SCENARIO-EVIDENCE.md for the evidence boundary and provenance details.
