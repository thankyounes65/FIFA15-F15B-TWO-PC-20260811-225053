#!/usr/bin/env python3
"""Turn v2 native-observer JSONL into the diagnostic verdict, per player and A/B.

The observer records raw probe hits. This reduces them to the five questions the
run exists to answer, and refuses to answer any of them for a probe that was
never armed - an absence of evidence from an unarmed probe is Not Reached, not a
negative result.

  1. did the accepted GameSetup reach the recovered MatchSession chain?
  2. at the bridge, does the incoming MSID still own bridge+0x98?
  3. was EVENT_MATCHUP_SUCCESS emitted?
  4. which 0x0B alternative executed: no-op, result-4 destroy, or virtual +8?
  5. was CardsDLL GetSquadList entered?

Usage:
  classify-native-observer-v2-evidence.py --player-a A.jsonl [--player-b B.jsonl]
  classify-native-observer-v2-evidence.py --self-test
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

CHAIN_ORDER = [
    "gamesetup_virtual_success_callsite",
    "matchmaking_operation_plus8",
    "matchmaking_operation_plus28",
    "matchmaking_reas3_result_apply",
    "matchsession_bridge_entry",
    "matchsession_bridge_owner_match",
    "event_matchup_success_emitter",
    "zero_b_window_entry",
    "zero_b_result4_destroy",
    "zero_b_virtual_plus8_arm",
    "cards_get_squad_list",
]

NOT_REACHED = "Not Reached"


def load(path: Path) -> list[dict]:
    events = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            events.append(json.loads(raw))
        except json.JSONDecodeError:
            continue
    return events


def analyse(events: list[dict]) -> dict:
    armed = {e["probe"] for e in events if e.get("type") == "probe_armed"}
    saturated = {e["probe"] for e in events if e.get("type") == "probe_saturated"}
    mismatched = {e["probe"] for e in events if e.get("type") == "probe_byte_mismatch"}
    ready = any(e.get("type") == "observer_ready" for e in events)
    fatal = any(e.get("type") == "observer_fatal" for e in events)
    hits: dict[str, list[dict]] = {}
    for e in events:
        if e.get("type") == "probe_hit":
            hits.setdefault(str(e.get("probe")), []).append(e)

    def state(probe: str) -> str:
        if probe in mismatched:
            return "VOID (byte mismatch)"
        if probe not in armed:
            return NOT_REACHED
        return "HIT" if hits.get(probe) else "ARMED-NO-HIT"

    # 2. bridge ownership
    bridge_verdict = NOT_REACHED
    bridge_detail = {}
    if "matchsession_bridge_entry" in armed:
        entries = hits.get("matchsession_bridge_entry", [])
        if not entries:
            bridge_verdict = "bridge never entered"
        else:
            last = entries[-1].get("bridge", {}) or {}
            bridge_detail = last
            if last.get("active_is_null"):
                bridge_verdict = "NO ACTIVE SESSION (bridge+0x98 was null)"
            elif "matchsession_bridge_owner_match" in armed:
                bridge_verdict = ("INCOMING MSID OWNS THE BRIDGE"
                                  if hits.get("matchsession_bridge_owner_match")
                                  else "OWNERSHIP LOST (compare mismatched)")
            else:
                bridge_verdict = "owner-match probe not armed: Unresolved"

    # 4. 0x0B classification
    if "zero_b_window_entry" not in armed:
        zero_b = NOT_REACHED
    elif not hits.get("zero_b_window_entry"):
        zero_b = "window never entered"
    elif hits.get("zero_b_result4_destroy"):
        zero_b = "result-4 destroy"
    elif hits.get("zero_b_virtual_plus8_arm"):
        gates = hits["zero_b_virtual_plus8_arm"][-1].get("bytes_at", {}) or {}
        took = gates.get("rdi_plus_161") not in (0, None) and gates.get("rbp_plus_991") not in (0, None)
        zero_b = f"virtual +8 arm entered; call [rax+8] {'TAKEN' if took else 'REFUSED (gate zero)'}"
    else:
        zero_b = "no-op (window entered, neither decisive write executed)"

    ordering = [
        {"seq": e.get("seq"), "timestamp_ms": e.get("timestamp_ms"),
         "thread_id": e.get("thread_id"), "probe": e.get("probe")}
        for e in events if e.get("type") == "probe_hit"
    ]
    ordering.sort(key=lambda r: (r["timestamp_ms"] or 0, r["seq"] or 0))

    return {
        "observer_ready": ready,
        "observer_fatal": fatal,
        "armed": sorted(armed),
        "never_armed": [p for p in CHAIN_ORDER if p not in armed],
        "byte_mismatched": sorted(mismatched),
        "saturated": sorted(saturated),
        "probe_state": {p: state(p) for p in CHAIN_ORDER},
        "hit_counts": {p: len(hits.get(p, [])) for p in CHAIN_ORDER},
        "answers": {
            "reached_matchsession_chain": state("matchsession_bridge_entry"),
            "bridge_msid_ownership": bridge_verdict,
            "event_matchup_success": state("event_matchup_success_emitter"),
            "zero_b_branch": zero_b,
            "cards_get_squad_list": state("cards_get_squad_list"),
        },
        "bridge_detail": bridge_detail,
        "ordering": ordering,
    }


def first_divergence(a: dict, b: dict) -> str:
    for probe in CHAIN_ORDER:
        sa, sb = a["probe_state"][probe], b["probe_state"][probe]
        if NOT_REACHED in (sa, sb):
            return (f"{probe}: cannot compare (A={sa}, B={sb}) - "
                    "the earliest comparable boundary is Not Reached on at least one side")
        if sa != sb:
            return f"{probe}: A={sa} B={sb}"
    if a["answers"]["zero_b_branch"] != b["answers"]["zero_b_branch"]:
        return (f"0x0B branch: A={a['answers']['zero_b_branch']} "
                f"B={b['answers']['zero_b_branch']}")
    if a["answers"]["bridge_msid_ownership"] != b["answers"]["bridge_msid_ownership"]:
        return (f"bridge ownership: A={a['answers']['bridge_msid_ownership']} "
                f"B={b['answers']['bridge_msid_ownership']}")
    return "no divergence across the instrumented chain"


def report(label: str, res: dict) -> None:
    print(f"--- {label} ---")
    print(f"  observer_ready={res['observer_ready']} observer_fatal={res['observer_fatal']}")
    if res["never_armed"]:
        print(f"  NEVER ARMED (absence here is Not Reached): {', '.join(res['never_armed'])}")
    if res["byte_mismatched"]:
        print(f"  BYTE MISMATCH (VOID for these probes): {', '.join(res['byte_mismatched'])}")
    if res["saturated"]:
        print(f"  SATURATED (counts are a floor): {', '.join(res['saturated'])}")
    for probe in CHAIN_ORDER:
        print(f"    {probe:<38} {res['probe_state'][probe]:<22} hits={res['hit_counts'][probe]}")
    print("  answers:")
    for k, v in res["answers"].items():
        print(f"    {k:<32} {v}")


def _fixture(armed, hits, extra=None):
    ev = [{"type": "observer_ready"}]
    for i, p in enumerate(armed):
        ev.append({"type": "probe_armed", "probe": p, "seq": i})
    seq = 100
    for p, payload in hits:
        seq += 1
        e = {"type": "probe_hit", "probe": p, "seq": seq, "timestamp_ms": seq, "thread_id": 1}
        e.update(payload or {})
        ev.append(e)
    ev.extend(extra or [])
    return ev


def self_test() -> int:
    failures = []
    full = CHAIN_ORDER

    # owner match present -> ownership held
    r = analyse(_fixture(full, [
        ("matchsession_bridge_entry", {"bridge": {"active_is_null": False, "incoming_msid": "2"}}),
        ("matchsession_bridge_owner_match", {})]))
    if r["answers"]["bridge_msid_ownership"] != "INCOMING MSID OWNS THE BRIDGE":
        failures.append(f"ownership-held misread: {r['answers']['bridge_msid_ownership']}")

    # entry but no match -> ownership lost
    r = analyse(_fixture(full, [
        ("matchsession_bridge_entry", {"bridge": {"active_is_null": False}})]))
    if r["answers"]["bridge_msid_ownership"] != "OWNERSHIP LOST (compare mismatched)":
        failures.append(f"ownership-lost misread: {r['answers']['bridge_msid_ownership']}")

    # null active session
    r = analyse(_fixture(full, [
        ("matchsession_bridge_entry", {"bridge": {"active_is_null": True}})]))
    if "NO ACTIVE SESSION" not in r["answers"]["bridge_msid_ownership"]:
        failures.append(f"null-active misread: {r['answers']['bridge_msid_ownership']}")

    # 0x0B: result-4 destroy
    r = analyse(_fixture(full, [("zero_b_window_entry", {}), ("zero_b_result4_destroy", {})]))
    if r["answers"]["zero_b_branch"] != "result-4 destroy":
        failures.append(f"result4 misread: {r['answers']['zero_b_branch']}")

    # 0x0B: virtual +8 taken and refused
    r = analyse(_fixture(full, [("zero_b_window_entry", {}),
                                ("zero_b_virtual_plus8_arm", {"bytes_at": {"rdi_plus_161": 1, "rbp_plus_991": 1}})]))
    if "TAKEN" not in r["answers"]["zero_b_branch"]:
        failures.append(f"virtual+8 taken misread: {r['answers']['zero_b_branch']}")
    r = analyse(_fixture(full, [("zero_b_window_entry", {}),
                                ("zero_b_virtual_plus8_arm", {"bytes_at": {"rdi_plus_161": 0, "rbp_plus_991": 1}})]))
    if "REFUSED" not in r["answers"]["zero_b_branch"]:
        failures.append(f"virtual+8 refused misread: {r['answers']['zero_b_branch']}")

    # 0x0B: no-op
    r = analyse(_fixture(full, [("zero_b_window_entry", {})]))
    if not r["answers"]["zero_b_branch"].startswith("no-op"):
        failures.append(f"no-op misread: {r['answers']['zero_b_branch']}")

    # unarmed probe must be Not Reached, never a negative
    r = analyse(_fixture([p for p in full if p != "cards_get_squad_list"], []))
    if r["answers"]["cards_get_squad_list"] != NOT_REACHED:
        failures.append("unarmed probe was not reported Not Reached")
    if r["answers"]["zero_b_branch"] != "window never entered":
        failures.append(f"armed-no-hit misread: {r['answers']['zero_b_branch']}")

    # byte mismatch is VOID
    r = analyse(_fixture(full, [], [{"type": "probe_byte_mismatch", "probe": "zero_b_window_entry"}]))
    if r["probe_state"]["zero_b_window_entry"] != "VOID (byte mismatch)":
        failures.append("byte mismatch not reported VOID")

    # ordering is monotonic by timestamp then seq
    r = analyse(_fixture(full, [("matchsession_bridge_entry", {}), ("event_matchup_success_emitter", {})]))
    ts = [o["timestamp_ms"] for o in r["ordering"]]
    if ts != sorted(ts):
        failures.append("ordering is not sorted")

    # A/B divergence
    a = analyse(_fixture(full, [("gamesetup_virtual_success_callsite", {}),
                                ("matchmaking_operation_plus8", {})]))
    b = analyse(_fixture(full, [("gamesetup_virtual_success_callsite", {})]))
    d = first_divergence(a, b)
    if not d.startswith("matchmaking_operation_plus8"):
        failures.append(f"divergence misidentified: {d}")

    if failures:
        for f in failures:
            print(f"FAIL: {f}")
        return 1
    print("PASS: bridge ownership held / lost / null-active all classify correctly.")
    print("PASS: 0x0B classifies result-4 destroy, virtual+8 taken, virtual+8 refused and no-op.")
    print("PASS: an unarmed probe reports Not Reached and a byte mismatch reports VOID;")
    print("      neither is ever reported as a negative result.")
    print("PASS: event ordering is monotonic and the earliest A/B divergence is identified.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--player-a", type=Path)
    ap.add_argument("--player-b", type=Path)
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if not args.player_a:
        print("need --player-a (and optionally --player-b)", file=sys.stderr)
        return 2
    a = analyse(load(args.player_a))
    report("PLAYER A", a)
    if args.player_b:
        b = analyse(load(args.player_b))
        report("PLAYER B", b)
        print("=== EARLIEST A/B DIVERGENCE ===")
        print(f"  {first_divergence(a, b)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
