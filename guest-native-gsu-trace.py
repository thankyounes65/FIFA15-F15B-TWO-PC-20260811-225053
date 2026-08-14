#!/usr/bin/env python3
"""Guarded read-only FIFA15 Player-B GameSetup/JoinCompleted/GSU tracer.

The exact FIFA executable is hash-pinned by PLAYER-B-KNOWN-GOOD.json. This tracer
also fails closed on runtime-decrypted instruction bytes before installing any
probe. It never modifies registers, branch conditions, lifecycle state, or
network state.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

EXPECTED_FIFA_SHA256 = "3da97d0a568475e5714e06f4871b814842a705ddc62207c2b9b66b5fc085bffb"
MODULE_NAME = "fifa15.exe"

# Exact runtime-decrypted bytes captured from the same executable hash on Player A
# during run 20260814-092344. These are mid-function sites already proven safe by
# the host tracer; any mismatch makes the guest run VOID rather than guessed.
SITES = {
    "gamesetup_dispatcher": (0x4859535, "c644246d00"),
    "gamesetup_decode_result": (0x485955B, "0fb74710"),
    "pros_registration_complete": (0x478C50E, "4889d8"),
    "join_handler": (0x47BEBEF, "4889d7"),
    "join_game_lookup": (0x47BEBFB, "4889c3"),
    "join_player_lookup": (0x47BEC0F, "4885c0"),
    "join_callback": (0x47BEC14, "488d8b40040000"),
    "join_exit": (0x47BEC2A, "488b5c2430"),
    "gsu_before_game_lookup": (0x47BC56C, "488b5208"),
    "gsu_game_lookup_result": (0x47BC57B, "4889c3"),
    "gsu_local_index_gate": (0x47BC599, "0f8522010000"),
    "gsu_network_predicate": (0x47BC5B7, "84c0"),
    "gsu_local_player_state": (0x47BC5ED, "418b4040"),
    "gsu_game_flag_gate": (0x47BC5F9, "389300080000"),
    "gsu_callback_d0": (0x47BC654, "ff90d0000000"),
    "gsu_callback_c8": (0x47BC673, "ff90c8000000"),
    "gsu_callback_90": (0x47BC6A9, "ff9090000000"),
    "gsu_fallback_callback": (0x47BC6B7, "e851f8feff"),
}

JS = r'''
const MODULE_NAME = "fifa15.exe";
const SITES = __SITES__;
const VERIFY_RETRY_TIMEOUT_MS = 120000;
const VERIFY_RETRY_INTERVAL_MS = 500;
const GSU_STALKER_WINDOW_MS = 150;
const GSU_STALKER_EVENT_CAP = 256;
const GSU_REGION_START_RVA = 0x47bc540;
const GSU_REGION_END_RVA = 0x47bc720;
let moduleBase = null;
let sequence = 0;
const joinThreads = {};
const gsuThreads = {};
const gsuPostPredicateTrace = {};

function now(type, extra) {
    sequence += 1;
    send(Object.assign({type:type, seq:sequence, thread_id:Process.getCurrentThreadId(), timestamp_ms:Date.now()}, extra || {}));
}
function bytesToHex(buf) {
    if (buf === null) return null;
    const view = new Uint8Array(buf); let out = "";
    for (let i=0;i<view.length;i++) out += view[i].toString(16).padStart(2,"0");
    return out;
}
function pointerString(value) { try { return value ? value.toString() : null; } catch (_) { return null; } }
function safeU32(address) { try { return address && !address.isNull() ? address.readU32() : null; } catch (_) { return null; } }
function safeU8(address) { try { return address && !address.isNull() ? address.readU8() : null; } catch (_) { return null; } }
function safeU64String(address) { try { return address && !address.isNull() ? address.readU64().toString() : null; } catch (_) { return null; } }
function playerState(player) { return player && !player.isNull() ? safeU32(player.add(0x40)) : null; }
function joinValues(object) {
    if (!object || object.isNull()) return {object:null,gid:null,pid:null};
    return {object:object.toString(), gid:safeU64String(object.add(0x8)), pid:safeU64String(object.add(0x10))};
}
function inGsuRegion(value) {
    try {
        const address = ptr(value), start = moduleBase.add(GSU_REGION_START_RVA), end = moduleBase.add(GSU_REGION_END_RVA);
        return address.compare(start) >= 0 && address.compare(end) < 0;
    } catch (_) { return false; }
}
function eventValue(value) {
    try {
        if (value === null || value === undefined) return null;
        if (typeof value === "number" || typeof value === "string" || typeof value === "boolean") return value;
        return value.toString();
    } catch (_) { return "<unprintable>"; }
}
function startGsuTrace(tid, predicate, gid) {
    if (gsuPostPredicateTrace[tid]) return;
    const state = {emitted:0,dropped:0}; gsuPostPredicateTrace[tid] = state;
    now("guest_gsu_branch_trace_started", {gid:gid,network_predicate:predicate,window_ms:GSU_STALKER_WINDOW_MS});
    try {
        Stalker.follow(tid, {
            events:{call:true,ret:true,exec:false,block:true,compile:false},
            onReceive:function(events) {
                let parsed=[];
                try { parsed=Stalker.parse(events,{annotate:false,stringify:false}); }
                catch(error) { now("guest_gsu_branch_trace_error",{stage:"parse",error:String(error)}); return; }
                for (const row of parsed) {
                    const from=row.length>1?row[1]:null;
                    if (!inGsuRegion(from)) continue;
                    if (state.emitted>=GSU_STALKER_EVENT_CAP) { state.dropped += 1; continue; }
                    state.emitted += 1;
                    now("guest_gsu_branch_event", {
                        gid:gid,network_predicate:predicate,event_kind:eventValue(row[0]),
                        from:eventValue(from),from_rva:from?ptr(from).sub(moduleBase).toString():null,
                        to:row.length>2?eventValue(row[2]):null,depth:row.length>3?eventValue(row[3]):null
                    });
                }
            }
        });
    } catch(error) {
        delete gsuPostPredicateTrace[tid];
        now("guest_gsu_branch_trace_error",{stage:"follow",error:String(error)}); return;
    }
    setTimeout(function(){
        try{Stalker.unfollow(tid);}catch(_){} try{Stalker.flush();}catch(_){} try{Stalker.garbageCollect();}catch(_){}
        now("guest_gsu_branch_trace_finished",{gid:gid,network_predicate:predicate,emitted:state.emitted,dropped_after_cap:state.dropped});
        delete gsuPostPredicateTrace[tid];
    },GSU_STALKER_WINDOW_MS);
}
function verifyAndInstall(label, callback, done) {
    const site=SITES[label], target=moduleBase.add(site.rva), expected=site.hex.toLowerCase(), size=expected.length/2;
    const deadline=Date.now()+VERIFY_RETRY_TIMEOUT_MS; let attempts=0;
    function attempt(){
        attempts += 1; let actual=null;
        try{actual=bytesToHex(target.readByteArray(size));}catch(_){}
        if(actual===expected){
            try{Interceptor.attach(target,{onEnter:callback}); now("guest_probe_installed",{probe:label,rva:"0x"+site.rva.toString(16),expected_hex:expected,attempts:attempts}); done(true);}
            catch(error){now("guest_probe_install_error",{probe:label,error:String(error)});done(false);} return;
        }
        if(Date.now()>=deadline){now("guest_probe_install_error",{probe:label,error:`expected=${expected} actual=${actual}`,attempts:attempts});done(false);return;}
        if(attempts===1||attempts%20===0) now("guest_probe_wait_retry",{probe:label,actual_hex:actual,attempts:attempts});
        setTimeout(attempt,VERIFY_RETRY_INTERVAL_MS);
    }
    attempt();
}
const callbacks = {
    gamesetup_dispatcher:function(){now("guest_gamesetup_dispatcher_entry",{});},
    gamesetup_decode_result:function(){now("guest_gamesetup_decode_result",{success:this.context.rax?((this.context.rax.toUInt32()&0xff)!==0):null});},
    pros_registration_complete:function(){now("guest_pros_registration_complete",{player:pointerString(this.context.rbx),player_state_plus_0x40:playerState(this.context.rbx)});},
    join_handler:function(){const tid=Process.getCurrentThreadId(),v=joinValues(this.context.rdx);joinThreads[tid]={gid:v.gid,pid:v.pid};now("guest_joincompleted_handler_entry",v);},
    join_game_lookup:function(){const tid=Process.getCurrentThreadId();now("guest_joincompleted_game_lookup",{gid:joinThreads[tid]?joinThreads[tid].gid:null,pid:joinThreads[tid]?joinThreads[tid].pid:null,game:pointerString(this.context.rax),lookup_hit:!!this.context.rax&&!this.context.rax.isNull()});},
    join_player_lookup:function(){const tid=Process.getCurrentThreadId();now("guest_joincompleted_player_lookup",{gid:joinThreads[tid]?joinThreads[tid].gid:null,pid:joinThreads[tid]?joinThreads[tid].pid:null,player:pointerString(this.context.rax),lookup_hit:!!this.context.rax&&!this.context.rax.isNull(),player_state_plus_0x40:playerState(this.context.rax)});},
    join_callback:function(){const tid=Process.getCurrentThreadId();now("guest_joincompleted_callback_taken",{gid:joinThreads[tid]?joinThreads[tid].gid:null,pid:joinThreads[tid]?joinThreads[tid].pid:null,player:pointerString(this.context.rax),player_state_plus_0x40:playerState(this.context.rax)});},
    join_exit:function(){const tid=Process.getCurrentThreadId();now("guest_joincompleted_handler_exit",joinThreads[tid]||{});delete joinThreads[tid];},
    gsu_before_game_lookup:function(){const tid=Process.getCurrentThreadId(),n=this.context.rdx;gsuThreads[tid]={gid:n?safeU64String(n.add(0x8)):null};now("guest_gamesessionupdated_handler_entry",{gid:gsuThreads[tid].gid,notification:pointerString(n)});},
    gsu_game_lookup_result:function(){const tid=Process.getCurrentThreadId();now("guest_gamesessionupdated_game_lookup",{gid:gsuThreads[tid]?gsuThreads[tid].gid:null,game:pointerString(this.context.rax),lookup_hit:!!this.context.rax&&!this.context.rax.isNull()});},
    gsu_local_index_gate:function(){const tid=Process.getCurrentThreadId();now("guest_gamesessionupdated_local_index_gate",{gid:gsuThreads[tid]?gsuThreads[tid].gid:null,requested_local_index:this.context.rsi?this.context.rsi.toUInt32():null,installed_local_index:this.context.r9?safeU32(this.context.r9.add(0x460)):null});},
    gsu_network_predicate:function(){const tid=Process.getCurrentThreadId(),p=this.context.rax?(this.context.rax.toUInt32()&0xff):null,g=gsuThreads[tid]?gsuThreads[tid].gid:null;now("guest_gamesessionupdated_network_gate",{gid:g,network_predicate:p,game_flag_plus_0x800:this.context.rbx?safeU8(this.context.rbx.add(0x800)):null});startGsuTrace(tid,p,g);},
    gsu_local_player_state:function(){const tid=Process.getCurrentThreadId(),p=this.context.r8;now("guest_gamesessionupdated_local_player",{gid:gsuThreads[tid]?gsuThreads[tid].gid:null,player:pointerString(p),player_state_plus_0x40:playerState(p)});},
    gsu_game_flag_gate:function(){const tid=Process.getCurrentThreadId();now("guest_gamesessionupdated_game_flag_gate",{gid:gsuThreads[tid]?gsuThreads[tid].gid:null,game_flag_plus_0x800:this.context.rbx?safeU8(this.context.rbx.add(0x800)):null});},
    gsu_callback_d0:function(){now("guest_gamesessionupdated_downstream_callback",{path:"manager_vtable_d0"});},
    gsu_callback_c8:function(){now("guest_gamesessionupdated_downstream_callback",{path:"manager_vtable_c8"});},
    gsu_callback_90:function(){now("guest_gamesessionupdated_downstream_callback",{path:"manager_vtable_90"});},
    gsu_fallback_callback:function(){now("guest_gamesessionupdated_downstream_callback",{path:"component_fallback"});}
};
function installAll(){
    const module=Process.getModuleByName(MODULE_NAME);moduleBase=module.base;
    now("guest_native_module",{base:module.base.toString(),size:module.size});
    const labels=Object.keys(SITES);let pending=labels.length,ok=0;
    for(const label of labels){verifyAndInstall(label,callbacks[label],function(success){if(success)ok+=1;pending-=1;if(pending===0)now("guest_required_probes_ready",{ok:ok===labels.length,required_installed:ok,required_total:labels.length});});}
}
installAll();
'''


def js_sites() -> str:
    rows = {name: {"rva": rva, "hex": expected} for name, (rva, expected) in SITES.items()}
    return json.dumps(rows, separators=(",", ":"))


def render_js() -> str:
    return JS.replace("__SITES__", js_sites())


def self_test() -> int:
    assert EXPECTED_FIFA_SHA256 == "3da97d0a568475e5714e06f4871b814842a705ddc62207c2b9b66b5fc085bffb"
    assert len(SITES) == 18
    assert SITES["gsu_network_predicate"] == (0x47BC5B7, "84c0")
    assert SITES["gsu_local_player_state"] == (0x47BC5ED, "418b4040")
    source = render_js()
    for marker in ("guest_required_probes_ready", "guest_gsu_branch_event", "Stalker.follow", "guest_joincompleted_callback_taken"):
        assert marker in source
    print(f"PASS: guest native GSU tracer has {len(SITES)} exact-byte-guarded sites for FIFA SHA-256 {EXPECTED_FIFA_SHA256}.")
    return 0


def find_process(device, seconds: int) -> int:
    import frida
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            return device.get_process(MODULE_NAME).pid
        except frida.ProcessNotFoundError:
            time.sleep(0.5)
    raise RuntimeError("fifa15.exe did not appear before timeout")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pid", type=int)
    parser.add_argument("--wait", type=int, default=600)
    parser.add_argument("--jsonl", type=Path)
    parser.add_argument("--text", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    try:
        import frida
    except ImportError:
        print("FRIDA_MISSING: install once with: python -m pip install frida", file=sys.stderr)
        return 40
    device = frida.get_local_device()
    try:
        pid = args.pid if args.pid is not None else find_process(device, args.wait)
        session = device.attach(pid)
    except Exception as error:
        print(f"guest native tracer attach failed: {error}", file=sys.stderr)
        return 41
    json_handle = args.jsonl.open("w", encoding="utf-8") if args.jsonl else None
    text_handle = args.text.open("w", encoding="utf-8") if args.text else None
    ready = False
    failed = False
    counts: dict[str, int] = {}

    def emit_text(line: str) -> None:
        if text_handle:
            text_handle.write(line + "\n")
            text_handle.flush()
        print(line, flush=True)

    def on_message(message, _data):
        nonlocal ready, failed
        if message.get("type") == "error":
            failed = True
            emit_text(f"[SCRIPT ERROR] {message.get('description')}")
            return
        payload = message.get("payload") or {}
        kind = str(payload.get("type", "unknown"))
        counts[kind] = counts.get(kind, 0) + 1
        payload["_wallclock_iso"] = time.strftime("%Y-%m-%dT%H:%M:%S")
        if json_handle:
            json_handle.write(json.dumps(payload, sort_keys=True, default=str) + "\n")
            json_handle.flush()
        if kind == "guest_required_probes_ready":
            ready = bool(payload.get("ok"))
            failed = not ready
            emit_text(f"[NATIVE PROBES {'READY' if ready else 'VOID'}] {payload.get('required_installed')}/{payload.get('required_total')}")
        elif kind in {"guest_gamesessionupdated_network_gate", "guest_gsu_branch_trace_started", "guest_gsu_branch_trace_finished", "guest_joincompleted_callback_taken", "guest_gamesetup_decode_result"}:
            emit_text(f"[{kind}] {payload}")
        elif kind in {"guest_probe_install_error", "guest_gsu_branch_trace_error"}:
            failed = True
            emit_text(f"[{kind}] {payload}")

    session.on("detached", lambda reason, *rest: emit_text(f"[session detached] reason={reason} {rest}"))
    script = session.create_script(render_js())
    script.on("message", on_message)
    script.load()
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
        if json_handle:
            json_handle.close()
        if text_handle:
            text_handle.close()
    print("guest native tracer counts=" + json.dumps(counts, sort_keys=True), flush=True)
    if failed or not ready:
        return 42
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
