# FIFA15 Player B Matchmaking Native Observer

**Subsystem:** FUT Online Single Match matchmaking - logical joiner MatchSession success boundary

**Purpose:** one synchronized, read-only, unchanged-wire capture with Player A. There is no scenario selector and no protocol candidate on Player B.

**Player B branch:** `integration/test-matchmaking-native-observer-v1`

**Player A required branch:** `thankyounes65/fifa15-relay-clean` / `integration/test-matchmaking-native-observer-v1`

**Binary/runtime state:** existing `PLAYER-B-KNOWN-GOOD.json` and `VERIFY-PLAYER-B-GAME-FILES.ps1` remain authoritative for the Player B game/DLL set. The observer targets retail `fifa15.exe` SHA-256 `3DA97D0A568475E5714E06F4871B814842A705DDC62207C2B9B66B5FC085BFFB` and uses the existing boot, Tailscale, loopback-forwarder, LSX, certificate-patch, and network-observer stack unchanged.

**Observer targets:** `0x47BCC7C -> 0x479EBE9 -> 0x479BC0B -> 0x3A04A32 -> 0x3715903`; bridge comparison points `0x3A04A46`/`0x3A04A5F`; every executed instruction in `0x47BE327..0x47BE448`; CardsDLL `+0x3BAB0`. The observer also records `0x479B785` as the adjacent operation `+0x28` hop.

**Safety/evidence rule:** recovered FIFA function entries are observed through a short Stalker window started from the already proven exact-byte GameSetup seed. The observer does not alter registers, branches, network messages, or lifecycle state. If the seed-byte check or Frida setup fails, the attempt is VOID.

**Exact actions:** run `RUN-FIFA15-F15B.bat` as Administrator while Player A is waiting in its matching observer peer gate. After both FIFA clients are launched, enter FUT Online Single Match; A searches first and B second. Do not cancel, retry, or select any old scenario. Close FIFA normally after the first divergence window is captured.

**Diagnostic success:** Player B evidence proves whether its MatchSession bridge owns incoming MSID 2, whether `EVENT_MATCHUP_SUCCESS` is emitted, which `0x0B` lifetime path executes, and whether CardsDLL `GetSquadList` is entered. UI success is useful evidence but is not required for the diagnostic to resolve the question.

**Evidence:** `runs/matchmaking-native-observer/player-b/<timestamp>/native-observer.jsonl`, `native-observer.txt`, and `OBSERVER-RUN-MANIFEST.txt`, plus normal Player B network/diagnostic artifacts from the inherited stack.

**VOID:** wrong A/B branch, known-good file verification failure, peer attestation failure, observer not live, Frida/script error, stale FIFA process, or truncated decision-window evidence.
