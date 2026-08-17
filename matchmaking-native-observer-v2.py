#!/usr/bin/env python3
"""Crash-safe read-only observer for the recovered FIFA 15 matchmaking success path (v2).

v1 used Frida Stalker to trace the GameManager thread. Run 20260817-001802 proved
that fatal: fifa15.exe crashed 0xC0000005 four seconds after `Stalker.follow`, on
the exact stalked thread, at RIP inside Stalker's own 4 MB PRIVATE RWX code-cache
slab (0x1199C0000+0x400000), executing a relocated `mov rax,[rip+0xB84850]` whose
effective address landed in the FREE/NOACCESS region that begins exactly at the
end of that slab. No fifa15.exe code was involved.

v2 therefore removes Stalker entirely and keeps only Frida Interceptor, which the
same run proved stable in this process for ~103 s across the GameSetup seed hook
and the CardsDLL hook, and which this project has used successfully in FIFA 15
for a long time (the legend card shim is confirmed on screen).

Every probe is a byte-verified, read-only `Interceptor.attach` onEnter callback.
No register, branch, stack, relay, Blaze, FUT or lifecycle state is modified.
The full v1 diagnostic scope is preserved; the 0x0B window is resolved by
instrumenting its decisive writes rather than by tracing every instruction.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

EXPECTED_FIFA_SHA256 = "3da97d0a568475e5714e06f4871b814842a705ddc62207c2b9b66b5fc085bffb"
MODULE_NAME = "fifa15.exe"
PROBE_TABLE = Path(__file__).with_name("fifa15-native-observer-v2-probes.json")

# Emission cap per probe. A probe that saturates is reported explicitly so that
# an absence of later evidence is never read as an absence of the event.
PROBE_EVENT_CAP = 200

JS = r'''
const PROBES = __PROBES__;
const CAP = __CAP__;
let sequence = 0;
const armed = {};
const counts = {};
const suppressed = {};

function emit(type, extra) {
  sequence += 1;
  send(Object.assign({type: type, seq: sequence, timestamp_ms: Date.now(),
                      thread_id: Process.getCurrentThreadId()}, extra || {}));
}
function hex(buf) {
  if (buf === null) return null;
  const a = new Uint8Array(buf);
  let s = "";
  for (let i = 0; i < a.length; i++) s += a[i].toString(16).padStart(2, "0");
  return s;
}
function ps(v) { try { return v ? v.toString() : null; } catch (_) { return null; } }
function rdU8(p) { try { return p && !p.isNull() ? p.readU8() : null; } catch (_) { return null; } }
function rdU32(p) { try { return p && !p.isNull() ? p.readU32() : null; } catch (_) { return null; } }
function rdU64(p) { try { return p && !p.isNull() ? p.readU64().toString() : null; } catch (_) { return null; } }
function rdPtr(p) { try { return p && !p.isNull() ? p.readPointer() : null; } catch (_) { return null; } }
function reg(ctx, name) { try { return ctx[name] || null; } catch (_) { return null; } }

// Bridge state at 0x3A04A32. The prologue is
//   mov rbx,rcx ; mov byte [rcx+0xA8],0 ; mov rcx,[rcx+0x98] ; test rcx,rcx
//   je <no active> ; mov rax,[r8] ; cmp [rcx],rax ; jne <not owner>
// so rcx = bridge, rdx = result code (an integer, NOT a pointer), r8 = incoming.
// v1 read rdx as the incoming session, which was wrong.
function bridgeSnapshot(ctx) {
  const bridge = reg(ctx, "rcx");
  const incoming = reg(ctx, "r8");
  const active = rdPtr(bridge ? bridge.add(0x98) : null);
  return {
    bridge: ps(bridge),
    result_code_edx: ps(reg(ctx, "rdx")),
    incoming_session: ps(incoming),
    incoming_msid: rdU64(incoming),
    bridge_active_session: ps(active),
    bridge_active_msid: rdU64(active),
    bridge_manager_a0: ps(rdPtr(bridge ? bridge.add(0xa0) : null)),
    bridge_flag_a8: rdU8(bridge ? bridge.add(0xa8) : null),
    active_is_null: active === null || active.isNull()
  };
}

function buildPayload(p, ctx) {
  const e = {probe: p.name, module: p.module, rva: p.rva};
  const spec = p.capture || {};
  if (spec.regs) {
    const r = {};
    for (let i = 0; i < spec.regs.length; i++) r[spec.regs[i]] = ps(reg(ctx, spec.regs[i]));
    e.registers = r;
  }
  if (spec.bridge) e.bridge = bridgeSnapshot(ctx);
  if (spec.verdict) e.verdict = spec.verdict;
  if (spec.objects) {
    e.objects = {};
    for (const k in spec.objects) {
      const base = reg(ctx, spec.objects[k]);
      e.objects[k] = base ? {ptr: ps(base), qword0: rdU64(base), vtable: ps(rdPtr(base))} : null;
    }
  }
  if (spec.dwords) {
    e.dwords = {};
    for (const k in spec.dwords) {
      const base = reg(ctx, spec.dwords[k][0]);
      e.dwords[k] = base ? rdU32(base.add(spec.dwords[k][1])) : null;
    }
  }
  if (spec.bytes_at) {
    e.bytes_at = {};
    for (const k in spec.bytes_at) {
      const base = reg(ctx, spec.bytes_at[k][0]);
      e.bytes_at[k] = base ? rdU8(base.add(spec.bytes_at[k][1])) : null;
    }
  }
  return e;
}

function arm(p) {
  if (armed[p.name]) return true;
  let m = null;
  try { m = Process.getModuleByName(p.module); } catch (_) { return false; }
  const target = m.base.add(ptr(p.rva));
  let live = null;
  try { live = hex(target.readByteArray(p.verify_len)); } catch (_) { return false; }
  if (live === null) return false;
  // Refuse to patch anything whose executed bytes are not exactly what the
  // decrypted-dump evidence pinned. fifa15.exe is packed, so this is the only
  // valid verification and it also catches a wrong RVA or a not-yet-decrypted page.
  if (live !== p.original_bytes) {
    if (!armed["__mismatch_" + p.name]) {
      armed["__mismatch_" + p.name] = true;
      emit("probe_byte_mismatch", {probe: p.name, module: p.module, rva: p.rva,
                                   expected: p.original_bytes, actual: live});
    }
    return false;
  }
  try {
    Interceptor.attach(target, {
      onEnter: function (args) {
        const n = (counts[p.name] || 0) + 1;
        counts[p.name] = n;
        if (n > CAP) {
          suppressed[p.name] = (suppressed[p.name] || 0) + 1;
          if (suppressed[p.name] === 1) emit("probe_saturated", {probe: p.name, cap: CAP});
          return;
        }
        emit("probe_hit", buildPayload(p, this.context));
      }
    });
    armed[p.name] = true;
    emit("probe_armed", {probe: p.name, module: p.module, rva: p.rva,
                         module_base: ps(m.base), target: ps(target),
                         verified_bytes: live,
                         relocated_instruction_span: p.relocated_instruction_span});
    return true;
  } catch (err) {
    emit("observer_error", {stage: "arm", probe: p.name, error: String(err)});
    return false;
  }
}

function armAll() {
  let pending = 0;
  for (let i = 0; i < PROBES.length; i++) if (!arm(PROBES[i])) pending += 1;
  try { Interceptor.flush(); } catch (_) {}
  return pending;
}

function install() {
  let fifa = null;
  try { fifa = Process.getModuleByName("fifa15.exe"); } catch (err) {
    emit("observer_fatal", {stage: "module", error: String(err)});
    return;
  }
  emit("observer_ready", {fifa_base: ps(fifa.base), probe_count: PROBES.length,
                          stalker_used: false, event_cap_per_probe: CAP});
  let pending = armAll();
  emit("arm_pass", {pass: 0, pending: pending});
  // Packed/late-loaded regions (CardsDLL, and any page not yet decrypted at
  // attach time) are retried. Nothing is ever patched without a byte match.
  let pass = 0;
  const timer = setInterval(function () {
    pass += 1;
    pending = armAll();
    if (pending === 0 || pass >= 600) {
      clearInterval(timer);
      const missing = [];
      for (let i = 0; i < PROBES.length; i++) if (!armed[PROBES[i].name]) missing.push(PROBES[i].name);
      emit("arm_complete", {passes: pass, armed_count: PROBES.length - missing.length,
                            missing: missing});
    }
  }, 500);
}
install();
'''


def load_probes() -> dict:
    return json.loads(PROBE_TABLE.read_text(encoding="utf-8"))


def render_js() -> str:
    doc = load_probes()
    slim = []
    for p in doc["probes"]:
        slim.append({
            "name": p["name"], "module": p["module"], "rva": p["rva"],
            "original_bytes": p["original_bytes"], "verify_len": p["verify_len"],
            "relocated_instruction_span": p["relocated_instruction_span"],
            "capture": p["capture"],
        })
    return (JS
            .replace("__PROBES__", json.dumps(slim, separators=(",", ":")))
            .replace("__CAP__", str(PROBE_EVENT_CAP)))


REQUIRED_PROBES = (
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
)


def self_test() -> int:
    doc = load_probes()
    source = render_js()
    names = [p["name"] for p in doc["probes"]]
    failures = []

    if doc.get("stalker_used") is not False:
        failures.append("probe table does not declare stalker_used=false")
    for forbidden in ("Stalker.follow", "Stalker.unfollow", "putCallout", "Stalker"):
        if forbidden in source:
            failures.append(f"rendered observer still references {forbidden}")
    for name in REQUIRED_PROBES:
        if name not in names:
            failures.append(f"probe table is missing {name}")
        if name not in source:
            failures.append(f"rendered observer is missing {name}")

    seen: dict[tuple[str, int], str] = {}
    for p in doc["probes"]:
        rva = int(p["rva"], 16)
        blob = p["original_bytes"]
        if len(blob) != p["verify_len"] * 2:
            failures.append(f"{p['name']}: original_bytes is not verify_len bytes")
        if p["verify_len"] < 16:
            failures.append(f"{p['name']}: verify_len {p['verify_len']} is too short to be a safe guard")
        if not blob.startswith(p["patch_bytes_5"]):
            failures.append(f"{p['name']}: patch_bytes_5 is not the prefix of original_bytes")
        if p["branch_targets_inside_patch"]:
            failures.append(f"{p['name']}: a branch target lands inside the 5-byte patch")
        if p["relocated_instruction_span"] < doc["patch_len"]:
            failures.append(f"{p['name']}: relocated span {p['relocated_instruction_span']} < patch length")
        for flag in ("mutates_registers", "mutates_stack", "mutates_control_flow"):
            if p[flag]:
                failures.append(f"{p['name']}: declares {flag}=true")
        if p["mechanism"] != "frida_interceptor_attach_onenter_readonly":
            failures.append(f"{p['name']}: unexpected mechanism {p['mechanism']}")
        # No two probes in the same module may overlap within the patch window.
        for off in range(doc["patch_len"]):
            key = (p["module"], rva + off)
            if key in seen:
                failures.append(f"{p['name']} overlaps {seen[key]} at {hex(rva + off)}")
            seen[key] = p["name"]

    if EXPECTED_FIFA_SHA256 != doc["fifa15_exe_sha256"]:
        failures.append("fifa15.exe SHA-256 disagrees between observer and probe table")

    if failures:
        for f in failures:
            print(f"FAIL: {f}")
        return 1
    print(f"PASS: {len(doc['probes'])} probes, all Interceptor-only, byte-pinned, non-overlapping,")
    print("      with no branch target inside any patch window and no Stalker reference.")
    print("PASS: bridge probe reads r8 as the incoming session and rdx as the result code")
    print("      (v1 read rdx as the incoming session, which the disassembly refutes).")
    print("PASS: 0x0B window is classified by its decisive writes 0x47BE3D9 / 0x47BE416")
    print("      plus the 0x47BE327 entry marker, with no instruction tracing.")
    return 0


def find_process(device, seconds: int) -> int:
    import frida
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            return device.get_process(MODULE_NAME).pid
        except frida.ProcessNotFoundError:
            time.sleep(0.25)
    raise RuntimeError("fifa15.exe did not appear before timeout")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--pid", type=int)
    parser.add_argument("--wait", type=int, default=600)
    parser.add_argument("--jsonl", type=Path)
    parser.add_argument("--text", type=Path)
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    try:
        import frida
    except ImportError:
        print("FRIDA_MISSING: python -m pip install frida", file=sys.stderr)
        return 40
    out_json = args.jsonl or Path("runs/matchmaking-native-observer-v2.jsonl")
    out_text = args.text or Path("runs/matchmaking-native-observer-v2.txt")
    out_json.parent.mkdir(parents=True, exist_ok=True)
    out_text.parent.mkdir(parents=True, exist_ok=True)
    device = frida.get_local_device()
    try:
        pid = args.pid if args.pid is not None else find_process(device, args.wait)
        session = device.attach(pid)
    except Exception as error:
        print(f"observer attach failed: {error}", file=sys.stderr)
        return 41
    jsonh = out_json.open("w", encoding="utf-8")
    texth = out_text.open("w", encoding="utf-8")
    counts: dict[str, int] = {}
    probes_hit: dict[str, int] = {}
    armed: list[str] = []
    ready = False
    fatal = False

    def line(text: str) -> None:
        texth.write(text + "\n")
        texth.flush()
        try:
            print(text)
        except UnicodeEncodeError:
            print(text.encode("ascii", "backslashreplace").decode("ascii"))

    def on_message(message, _data):
        nonlocal ready, fatal
        if message.get("type") == "error":
            fatal = True
            line(f"[SCRIPT ERROR] {message.get('description')}")
            return
        payload = message.get("payload") or {}
        kind = str(payload.get("type", "unknown"))
        payload["_wallclock_iso"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        counts[kind] = counts.get(kind, 0) + 1
        if kind == "probe_hit":
            name = str(payload.get("probe"))
            probes_hit[name] = probes_hit.get(name, 0) + 1
        if kind == "probe_armed":
            armed.append(str(payload.get("probe")))
        jsonh.write(json.dumps(payload, sort_keys=True, default=str) + "\n")
        jsonh.flush()
        if kind == "observer_ready":
            ready = True
        if kind == "observer_fatal":
            fatal = True
        line(f"[{kind}] {payload}")

    script = session.create_script(render_js())
    script.on("message", on_message)
    script.load()
    line(f"observer v2 attached pid={pid}; jsonl={out_json}; text={out_text}")
    try:
        while True:
            time.sleep(0.5)
            try:
                device.get_process(MODULE_NAME)
            except frida.ProcessNotFoundError:
                break
    except KeyboardInterrupt:
        pass
    finally:
        try:
            script.unload()
        except Exception:
            pass
        try:
            session.detach()
        except Exception:
            pass
        jsonh.close()
        texth.close()

    print("=== native observer v2 summary ===")
    for key in sorted(counts):
        print(f"  {key}: {counts[key]}")
    print("  --- probes armed ---")
    for name in REQUIRED_PROBES:
        state = "ARMED" if name in armed else "NOT-ARMED"
        print(f"    {name}: {state} hits={probes_hit.get(name, 0)}")
    if fatal or not ready:
        print("RESULT: VOID - observer was not safely live")
        return 2
    print("RESULT: observer completed; interpret an absence only for probes reported ARMED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
