# FIFA15 Player B Working-Server Peer QoS v7

**Subsystem:** FUT Online Single Match matchmaking — the notification that tells Player B its opponent's network data is current, which the real server sends 8 ms before GameSetup and Player A never has.

**Player B branch:** `integration/test-matchmaking-working-server-setup-burst-v3`

**Player A required branch:** `thankyounes65/fifa15-relay-clean` / `integration/test-matchmaking-working-server-setup-burst-v3`

**Player A build:** `build_pairing_working_server_peer_qos_v7.rs`, parent `build_pairing_working_server_lobby_entry_v4.rs`

**Candidate/package:** `FIFA15-MM-WORKING-SERVER-PEER-QOS-V7` / `F15B-MM-WORKING-SERVER-SETUP-BURST-V3`, peer gate TCP 48216.

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

**Player B is the joiner, and this candidate is again aimed squarely at Player
B's seat — this time using Player B's own capture as the primary evidence.**

Run `20260818-024947` landed every previous change on the wire and **still**
ended with Player B sending `SetPlayerAttributes {REQ:"1"}` and then going
silent. Retail's joiner sends a second `{REQ:"2"}` 1.77 s later.

Player B's lossless capture also **refuted** the previous candidate's premise.
Player A's UDP capture had suggested no peer traffic during the lobby; Player
B's capture shows bidirectional peer UDP before `REQ:"1"` in **both** runs
(~20 packets each). Peer UDP was never absent, and Player A's gameplay-UDP
summary must not be used to time it.

A complete command-level diff of every notification Player B received against
retail's joiner seat leaves exactly **one** gap:

> `UserSessions.NotifyUserSessionExtendedDataUpdate` (`0x7802::0x0001`) is
> **never sent about the OTHER player**.

Retail sends it 8 ms before GameSetup, every attempt, with a refreshed port.
Player A does send `0x0001` twice — but Player B's own wire shows both carry
**Player B's own** session id and both arrive before matchmaking, as replies to
Player B's `UpdateNetworkInfo`. Neither describes the opponent.

Retail's peer document, six fields, reproduced exactly (field-set identical):

```
{ DATA: { ADDR: <union arm 2: EXIP{IP,MACI,PORT}, INIP{...}, MACI>,
          HWFG: 0, QDAT: { DBPS, NATT, UBPS }, UATT: 0 },
  SUBS: 1,
  USID: <the OTHER player's session id> }
```

**Second, separately scored variable:** `QDAT.NATT` is published as **1**
(retail's value) instead of the observed **5**, which is what a client reports
when it has no QoS result — this appliance has no QoS server. `DBPS`/`UBPS`
stay 0 rather than copying retail's measured numbers.

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

The decisive question is unchanged: does Player B now advance past `{REQ:"1"}`?

Player A's scorecard must show:

```
                              20260818-024947           required now
peer 0x0001 sent              0                         2   (one per client)
peer NATT published open (1)  0                         >0
lobby REQ=1 broadcasts        2                         2
lobby REQ=2 broadcasts        0   <- the stall          >0  <- the fix working
```

**Player B's own capture is the authoritative artefact here**, and it is why
this package captures the wire:

1. Player B must **receive** a `0x7802/0x0001` whose `USID` is Player A's
   session id, arriving immediately before its `NotifyGameSetup`. Every
   previous run's `0x0001` carried Player B's own id.
2. Player B's Blaze stream must not end dead right after `{REQ:"1"}`.

Decode with
`python scripts/blaze-capture/extract-blaze-stream.py --pcap <file> --port 42128
--server-ip <Player A overlay ip> --outdir out` then `--outdir out --report`.
If the capture is on a Tailscale interface it is raw IPv4 with no Ethernet
header; convert first with `editcap -T rawip <in> <out>`.

## PASS / PARTIAL / CLEAN FAIL / VOID

- **PASS:** both clients reach the same usable pre-match lobby.
- **PARTIAL:** `REQ=2` appears but the run still stops short of a usable shared lobby. Record the new boundary — that is the first movement past this step.
- **CLEAN FAIL:** Player B's capture confirms it received the peer `0x0001` with Player A's `USID` and the open NAT type, the rest of the wire still scores at target, and Player B **still** sends only `{REQ:"1"}` then goes silent. That refutes this gap too, and means nothing in the Blaze notification stream gates `REQ:"2"` — the next move is reading what Player B's client does locally in that window, which no capture has yet shown.
- **VOID:** wrong A/B branch or package, failed preflight, peer-gate rejection, wrong search order, stale process, crash before GameSetup, missing evidence, or instrumentation reintroduced.

**Regression signal to watch:** this candidate inserts a notification
immediately before GameSetup, the most load-bearing document in the flow. If
Player B now goes silent *earlier* than in `20260818-024947` — no
`updateMeshConnection`, or no promotion — the new document is being rejected and
must be reverted rather than iterated on.

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
