# Player-B matchmaking scenario evidence

The Player-B scenario runner preserves one exact attempt under
`runs\matchmaking-scenarios\player-b\scenario-<id>-<slug>\<timestamp>\`.

Automatically preserved:

- the selected scenario id, candidate, expected A branch/build, B package, start/end time, and B revision when the package has a Git checkout;
- the rendered B runtime BAT and the scenario-suite JSON, each with SHA-256;
- the exact-attempt Player-B diagnostic, network-observer log, native-attestation log, and evidence ZIP when produced by that attempt, with SHA-256;
- a `PLAYER-B-OBSERVATION.txt` template tied to the same scenario and timestamp.

The operator should add an exact-time UI observation and any screenshot/video path to that template before zipping the scenario folder.

Evidence boundary: the B network observer establishes connectivity/reachability. The B native-attestation log is static and `native_execution_probe=false`; it cannot establish that a FIFA handler or callback executed. The Player-A exact relay trace remains the authoritative wire evidence for messages delivered to B. Treat a missing B callback as **Inconclusive** unless an instrument proved it was live.
