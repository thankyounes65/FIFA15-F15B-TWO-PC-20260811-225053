# FIFA15 Player B Working-Server Lobby Entry v4

**Subsystem:** FUT Online Single Match matchmaking — the host endpoint Player B uses to open its peer-to-peer flow, plus two matchmaking notifications Player A has never sent.

**Player B branch:** `integration/test-matchmaking-working-server-setup-burst-v3`

**Player A required branch:** `thankyounes65/fifa15-relay-clean` / `integration/test-matchmaking-working-server-setup-burst-v3`

**Player A build:** `build_pairing_working_server_lobby_entry_v4.rs`, parent `build_pairing_working_server_setup_burst_v3.rs`

**Candidate/package:** `FIFA15-MM-WORKING-SERVER-LOBBY-ENTRY-V4` / `F15B-MM-WORKING-SERVER-SETUP-BURST-V3`, peer gate TCP 48216.

**No instrumentation.** Nothing is attached to `fifa15.exe` on either machine. Player B remains a normal second client using the already-proven Tailscale/hosts/loopback/LSX/certificate/evidence stack. Retail `fifa15.exe` SHA-256 remains `3DA97D0A568475E5714E06F4871B814842A705DDC62207C2B9B66B5FC085BFFB` and no game file is modified. **Player B's wire is unchanged in this candidate** — the only variable is Player A's burst.

## Already Confirmed, and not under test

Run `20260817-064947` proved Leads 1–3 end to end, and Player A inherits them
unchanged here:

- every mesh `TCG` resolved to the real peer (0 unknown, previously all unknown);
- self announcements never promote; the genuine cross-player CONNECTED edge does;
- the client owns `GSTA=130` (v3 corrects only *when* the relay echoes it);
- both players then receive `GSTA130 → STAT=4 ×2 → JoinCompleted ×2`, once each, with no premature host `JoinCompleted`;
- neither client sends `leaveGameByGroup` any more.

The shared lobby still did not appear, which is why this run exists.

## Exact hypothesis

**Player B is the joiner, and this candidate is aimed squarely at Player B's seat.**

Run `20260818-012401` was valid and Player B's own wire capture was **lossless
(0 holes)**, so it settles what happened. Player B received the whole burst,
received `STAT=4` and `JoinCompleted` for **both** players, and sent
`SetPlayerAttributes {REQ:"1"}` — Player B did reach the lobby state machine.
Its Blaze stream then went silent for the remaining 123 seconds.

Retail's joiner sends a **second** `{REQ:"2"}` 1.77 s later, and only then does
the session move on. Player A never sending `SetPlayerAttributes` is correct —
both retail seats agree the host never sends one.

What precedes `{REQ:"2"}` in retail is the joiner **opening its peer-to-peer UDP
flow to the host**, addressed to exactly `GAME.HNET[0].EXIP.IP:PORT`, before it
even sends `{REQ:"1"}`. In run `20260818-012401` there was **no peer UDP at all
during the lobby** — the first peer packet arrived 87 seconds later.

The cause is a single encoding difference in the GameSetup Player B receives:

```
before  GAME.HNET[0] = arm 3  { IP, PORT }
now     GAME.HNET[0] = arm 2  { EXIP{IP,MACI,PORT}, INIP{IP,MACI,PORT}, MACI }
```

Arm 2 is Confirmed in two retail sessions, one lossless and in our own game
mode. Two further Confirmed additions ship with it, both **byte-identical** to
retail:

```
S 0x000C  NotifyMatchmakingAsyncStatus   after each StartMatchmaking ack
C 0x0004  SetGameSettings {GID, GSET}    -> answered by Player A
S 0x006E  {ATTR: <that GSET>, GID}       -> mirrored to BOTH seats
```

Player B's wire, boot stack and game files are **unchanged**. The only variable
is what Player A sends.

## Exact actions

1. Player A uses the Universal Branch Tester and selects `integration/test-matchmaking-working-server-setup-burst-v3`.
2. Player A must require `launch\VERIFY-BUILD.bat` to PASS before FIFA starts.
3. Player B uses a FRESH ZIP of this exact branch and runs `RUN-FIFA15-F15B.bat` as Administrator.
4. Require the peer gate to accept exact candidate/package `FIFA15-MM-WORKING-SERVER-SETUP-BURST-V3` / `F15B-MM-WORKING-SERVER-SETUP-BURST-V3`.
5. Both enter FUT → Online Single Match. **A searches first, B searches second.**
6. Do not cancel or retry after pairing.
7. If both reach the shared lobby, B readies first, then A. Continue toward kickoff only while stable.
8. If the joiner remains loading, leave the state visible briefly so evidence flushes, then close FIFA normally.

## Primary discriminator

The decisive question is whether Player B now advances past `{REQ:"1"}`.

Player A's scorecard must show:

```
                              20260818-012401           required now
HNET arm 2 (IpPairAddress)    0                         4
HNET arm 3 (bare IP)          4                         0   (must be 0)
0x000C async status sent      0                         2   (one per client)
lobby REQ=1 broadcasts        2                         2
lobby REQ=2 broadcasts        0   <- the stall          >0  <- the fix working
```

**Player B's own two artefacts settle the mechanism**, and they are the reason
this package captures the wire at all:

1. the gameplay UDP must start **during** the lobby, not ~87 s after it;
2. Player B's Blaze capture must not end dead right after `{REQ:"1"}`.

Decode it with
`python scripts/blaze-capture/extract-blaze-stream.py --pcap <file> --port 42128
--server-ip <Player A overlay ip> --outdir out` then `--outdir out --report`.
If the capture is on a Tailscale interface it may be raw IPv4 with no Ethernet
header; convert it first with `editcap -T rawip <in> <out>`.

## PASS / PARTIAL / CLEAN FAIL / VOID

- **PASS:** both clients reach the same usable pre-match lobby.
- **PARTIAL:** `REQ=2` appears and/or Player B's peer UDP now starts during the lobby, but the run still stops short of a usable shared lobby. Record the new boundary — that is real forward progress.
- **CLEAN FAIL:** HNET is confirmed arm 2 on the wire, `0x000C` is sent twice, the whole v3 burst still scores at target, and Player B **still** sends only `{REQ:"1"}` with no peer UDP during the lobby. That refutes the HNET arm as the blocker — a genuine result, not a wasted run.
- **VOID:** wrong A/B branch or package, failed preflight, peer-gate rejection, wrong search order, stale process, crash before GameSetup, missing evidence, or instrumentation reintroduced.

**Regression signal to watch:** `HNET` is the host endpoint Player B connects
to, and this candidate changes its encoding. If Player B now goes silent
*earlier* than in `20260818-012401` — no `updateMeshConnection`, or no promotion
— the arm 2 document is being rejected and the change must be reverted rather
than iterated on. Player B's wire capture shows which frame immediately preceded
any reset; Player A's relay log cannot.

## New in this package: the Player B wire capture

`RUN-FIFA15-F15B.bat` now starts a **filtered** pktmon capture before the peer
gate and stops it after FIFA closes, writing the `.pcapng`, the raw `.etl` and
`WIRE-CAPTURE-SUMMARY.txt` into this attempt's folder, which the evidence ZIP
already sweeps. It is passive NIC capture; nothing attaches to `fifa15.exe`.

It exists because Player A's relay log proves only what the relay **sent** —
"notification sent successfully" means its socket accepted the bytes. If FIFA
rejects a frame it resets the connection, and only a capture on this machine
shows which frame immediately preceded the RST.

The filter is narrow (TCP 42128/42127/42230/17502/17503, UDP 3659/11000/11001)
precisely so it cannot drop packets: the retail "golden" capture was unfiltered
and lost a whole frame out of the burst under investigation. The summary reports
pktmon's own drop counters, and if they are non-zero the capture is **not**
admissible as evidence that something was never sent.

## Required evidence

Player A: exact run manifest, `relay-full.log`, newest `fifa15-trace-*.jsonl`, scorecard, gameplay UDP summary and crash summary if applicable.

Player B: automatic evidence ZIP plus exact attempt manifest, now including the wire capture and its summary. Preserve any crash/WER evidence.

Do not exercise `USID` semantics, alternate GSU timing, consumables, club items, Legends, tournaments, another matchmaking scenario, or native instrumentation in this launch.
