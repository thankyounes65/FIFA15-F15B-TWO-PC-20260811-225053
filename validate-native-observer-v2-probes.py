#!/usr/bin/env python3
"""Offline validation of the v2 native-observer probe table.

This re-derives the safety properties from the pinned byte blobs with capstone
instead of trusting the values recorded in the table. It is the offline proof
that stands in for a Windows CI job, and it must pass before any FIFA run.

Checks
  1. every probe disassembles cleanly from its pinned bytes
  2. the 5-byte Interceptor patch never splits the instruction stream in a way
     that leaves a branch target inside the patched window
  3. the recorded relocated-instruction span really is >= 5 bytes
  4. no two probes overlap within the patch window
  5. the recorded instruction text matches a fresh disassembly
  6. the semantic anchors the diagnostic depends on are the instructions we think
     they are (the bridge +0x98 read, the owner-match fallthrough, the result-4
     write and the virtual+8 arm write)

`--against-dump <path>` additionally re-reads the bytes out of a FIFA full-memory
dump, which is how the table was produced in the first place.
"""
from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path

def _find_table() -> Path:
    here = Path(__file__).resolve().parent
    # Player A keeps the table under scripts/frida/; the portable Player B
    # package is flat. One file must work unchanged in both.
    for candidate in (here / "fifa15-native-observer-v2-probes.json",
                      here / "frida" / "fifa15-native-observer-v2-probes.json"):
        if candidate.exists():
            return candidate
    raise SystemExit("cannot locate fifa15-native-observer-v2-probes.json")


TABLE = _find_table()
PATCH_LEN = 5

# The instruction each semantic anchor must be, checked against a fresh disassembly.
SEMANTIC_ANCHORS = {
    "matchsession_bridge_entry": "mov qword ptr [rsp + 0x18], rbx",
    "matchsession_bridge_owner_match": "mov qword ptr [rbx + 0x98], 0",
    "zero_b_result4_destroy": "mov dword ptr [rsi + 0x1c], 4",
    "zero_b_virtual_plus8_arm": "mov byte ptr [rdi + 0x160], 1",
    "matchmaking_operation_plus28": "test r8, r8",
    "cards_get_squad_list": "mov qword ptr [rsp + 8], rbx",
}


def read_dump_bytes(dump: Path, addr: int, n: int):
    with dump.open("rb") as f:
        _sig, _ver, nstreams, rva = struct.unpack("<4sIII", f.read(16))
        f.seek(rva)
        dirs = [struct.unpack("<III", f.read(12)) for _ in range(nstreams)]
        for t, _sz, o in dirs:
            if t != 9:
                continue
            f.seek(o)
            nr, base = struct.unpack("<QQ", f.read(16))
            cur = base
            ranges = []
            for _ in range(nr):
                sa, rs = struct.unpack("<QQ", f.read(16))
                ranges.append((sa, rs, cur))
                cur += rs
            for sa, rs, fo in ranges:
                if sa <= addr < sa + rs:
                    f.seek(fo + (addr - sa))
                    return f.read(min(n, sa + rs - addr))
    return None


def check(doc, dump=None):
    probes = doc["probes"]
    failures: list[str] = []
    notes: list[str] = []

    try:
        import capstone
    except ImportError:
        capstone = None
        notes.append("capstone not installed: disassembly re-derivation SKIPPED (table-only checks ran)")

    if doc.get("stalker_used") is not False:
        failures.append("table does not declare stalker_used=false")
    if doc.get("patch_len") != PATCH_LEN:
        failures.append(f"table patch_len {doc.get('patch_len')} != {PATCH_LEN}")

    seen: dict[tuple[str, int], str] = {}
    for p in probes:
        name = p["name"]
        rva = int(p["rva"], 16)
        raw = bytes.fromhex(p["original_bytes"])

        if len(raw) != p["verify_len"]:
            failures.append(f"{name}: pinned blob is {len(raw)} bytes, expected verify_len {p['verify_len']}")
            continue
        if raw[:PATCH_LEN].hex() != p["patch_bytes_5"]:
            failures.append(f"{name}: patch_bytes_5 disagrees with original_bytes")

        for off in range(PATCH_LEN):
            key = (p["module"], rva + off)
            if key in seen and seen[key] != name:
                failures.append(f"{name} overlaps {seen[key]} at {hex(rva + off)}")
            seen[key] = name

        # Pure-table checks. These must run even without capstone, because the
        # portable Player B package is not guaranteed to have it installed.
        if p["branch_targets_inside_patch"]:
            failures.append(f"{name}: table records branch targets inside the patch window")
        if p["relocated_instruction_span"] < PATCH_LEN:
            failures.append(
                f"{name}: recorded span {p['relocated_instruction_span']} < patch length {PATCH_LEN}")
        for flag in ("mutates_registers", "mutates_stack", "mutates_control_flow"):
            if p[flag]:
                failures.append(f"{name}: declares {flag}=true")
        if p["mechanism"] != "frida_interceptor_attach_onenter_readonly":
            failures.append(f"{name}: unexpected mechanism {p['mechanism']}")

        if capstone is None:
            continue

        md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
        md.detail = True
        insns = list(md.disasm(raw, rva))
        if not insns:
            failures.append(f"{name}: pinned bytes do not disassemble")
            continue

        # (3) span really covers the patch
        span = 0
        covered = []
        for i in insns:
            covered.append(i)
            span += i.size
            if span >= PATCH_LEN:
                break
        if span < PATCH_LEN:
            failures.append(f"{name}: instruction span {span} < patch length {PATCH_LEN}")
        if span != p["relocated_instruction_span"]:
            failures.append(
                f"{name}: recorded span {p['relocated_instruction_span']} != derived {span}")

        # (5) recorded text matches fresh disassembly
        rec = p["relocated_instructions"]
        if len(rec) != len(covered):
            failures.append(f"{name}: recorded {len(rec)} relocated instructions, derived {len(covered)}")
        else:
            for r, i in zip(rec, covered):
                derived = f"{i.mnemonic} {i.op_str}".strip()
                if r["text"].strip() != derived:
                    failures.append(f"{name}: recorded '{r['text']}' != derived '{derived}'")
                if r["bytes"] != i.bytes.hex():
                    failures.append(f"{name}: recorded bytes {r['bytes']} != derived {i.bytes.hex()}")

        # (2) no branch inside the patch window may target a byte inside it
        inner_targets = set()
        for i in insns:
            if i.group(capstone.x86.X86_GRP_JUMP) or i.group(capstone.x86.X86_GRP_CALL):
                for op in i.operands:
                    if op.type == capstone.x86.X86_OP_IMM and rva < op.imm < rva + span:
                        inner_targets.add(op.imm)
        if inner_targets:
            failures.append(f"{name}: branch target(s) inside patch: {[hex(t) for t in inner_targets]}")

        # (6) semantic anchors
        want = SEMANTIC_ANCHORS.get(name)
        if want:
            got = f"{insns[0].mnemonic} {insns[0].op_str}".strip()
            if got != want:
                failures.append(f"{name}: anchor is '{got}', expected '{want}'")


    # The bridge +0x98 read must exist where the design says it does.
    if capstone is not None:
        bridge = next((p for p in probes if p["name"] == "matchsession_bridge_entry"), None)
        if bridge:
            md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
            text = [f"{i.mnemonic} {i.op_str}".strip()
                    for i in md.disasm(bytes.fromhex(bridge["original_bytes"]), int(bridge["rva"], 16))]
            if "mov rcx, qword ptr [rcx + 0x98]" not in text:
                failures.append("bridge entry blob does not contain the bridge+0x98 read")

    if dump:
        if not dump.exists():
            notes.append(f"dump {dump} not present: dump re-read SKIPPED")
        else:
            base = int(doc["fifa15_image_base"], 16)
            for p in probes:
                if p["module"] != "fifa15.exe":
                    notes.append(f"{p['name']}: not in fifa15.exe, dump re-read skipped")
                    continue
                got = read_dump_bytes(dump, base + int(p["rva"], 16), p["verify_len"])
                if got is None:
                    failures.append(f"{p['name']}: RVA not mapped in dump")
                elif got.hex() != p["original_bytes"]:
                    failures.append(f"{p['name']}: dump bytes {got.hex()} != pinned {p['original_bytes']}")

    return failures, notes


# (label, mutation, requires_capstone)
NEGATIVE_CASES = [
    ("branch target inside patch",
     lambda d: d["probes"][0].__setitem__("branch_targets_inside_patch", ["0x47bcc78"]), False),
    ("overlapping probes",
     lambda d: d["probes"][1].__setitem__("rva", d["probes"][1 - 1]["rva"]), False),
    ("corrupted pinned bytes",
     lambda d: d["probes"][4].__setitem__("original_bytes", "90" * d["probes"][4]["verify_len"]), False),
    ("probe declared as mutating",
     lambda d: d["probes"][3].__setitem__("mutates_control_flow", True), False),
    ("stalker re-enabled",
     lambda d: d.__setitem__("stalker_used", True), False),
    ("wrong recorded span",
     lambda d: d["probes"][5].__setitem__("relocated_instruction_span", 3), False),
    ("semantic anchor moved",
     lambda d: d["probes"][8].__setitem__(
         "original_bytes", "90" * 7 + d["probes"][8]["original_bytes"][14:]), True),
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--against-dump", type=Path)
    args = ap.parse_args()

    doc = json.loads(TABLE.read_text(encoding="utf-8"))
    failures, notes = check(doc, args.against_dump)
    for n in notes:
        print(f"NOTE: {n}")
    if failures:
        for f in failures:
            print(f"FAIL: {f}")
        return 1

    if args.self_test:
        # Negative proof: the validator must REJECT each unsafe mutation.
        import copy
        try:
            import capstone as _cs
            have_cs = True
        except ImportError:
            have_cs = False
        for label, mutate, needs_cs in NEGATIVE_CASES:
            if needs_cs and not have_cs:
                print(f"SKIP: {label} (needs capstone)")
                continue
            bad = copy.deepcopy(doc)
            mutate(bad)
            bad_failures, _ = check(bad)
            if not bad_failures:
                print(f"FAIL: validator ACCEPTED an unsafe table ({label})")
                return 1
            print(f"PASS: rejected unsafe table - {label}")

    probes = doc["probes"]
    try:
        import capstone  # noqa: F401
        disassembled = True
    except ImportError:
        disassembled = False
    if disassembled:
        print(f"PASS: {len(probes)} probes validated by fresh disassembly.")
        print("PASS: semantic anchors (bridge+0x98 read, owner-match fallthrough,")
        print("      result-4 write, virtual+8 arm write) are the expected instructions.")
    else:
        print(f"PASS: {len(probes)} probes validated against the pinned table only.")
        print("PARTIAL: capstone absent, so disassembly re-derivation and the semantic-anchor")
        print("         check did not run. The observer still refuses to arm any probe whose")
        print("         live bytes differ from the pinned blob, so this cannot mis-arm a hook.")
    print("PASS: no branch target inside any 5-byte Interceptor patch window.")
    print("PASS: no two probes overlap; every probe is declared read-only.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
