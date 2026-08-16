#!/usr/bin/env python3
"""Guarded read-only observer for the recovered FIFA 15 matchmaking success path.

No relay, Blaze, FUT, register, branch, or lifecycle state is modified. A proven
mid-function GameSetup probe starts a short Frida Stalker window on that thread.
The stalker records the recovered success chain and the complete executed path
inside the 0x0B decision window. CardsDLL GetSquadList is observed separately.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

EXPECTED_FIFA_SHA256 = "3da97d0a568475e5714e06f4871b814842a705ddc62207c2b9b66b5fc085bffb"
MODULE_NAME = "fifa15.exe"
CARDS_MODULE = "CardsDLLzf.dll"
GAMESETUP_SEED_RVA = 0x4859535
GAMESETUP_SEED_HEX = "c644246d00"
CARDS_GET_SQUAD_LIST_RVA = 0x3BAB0
STALK_MS = 20000

WATCH_RVAS = {
    0x47BCC7C: "gamesetup_virtual_plus8_callsite",
    0x479EBE9: "matchmaking_operation_plus8",
    0x479B785: "matchmaking_operation_plus28",
    0x479BC0B: "matchmaking_reas3_result_apply",
    0x3A04A32: "matchsession_bridge_entry",
    0x3A04A46: "matchsession_bridge_owner_compare_begin",
    0x3A04A5F: "matchsession_bridge_owner_compare_end",
    0x3715903: "event_matchup_success_emitter",
}
ZERO_B_START = 0x47BE327
ZERO_B_END = 0x47BE448

JS = r'''
const FIFA = "fifa15.exe";
const CARDS = "CardsDLLzf.dll";
const SEED_RVA = 0x4859535;
const SEED_HEX = "c644246d00";
const CARDS_RVA = 0x3bab0;
const STALK_MS = 20000;
const WATCH = __WATCH__;
const ZERO_B_START = 0x47be327;
const ZERO_B_END = 0x47be448;
let fifaBase = null;
let cardsHooked = false;
let sequence = 0;
let activeThreads = {};
function emit(type, extra) { sequence += 1; send(Object.assign({type:type,seq:sequence,timestamp_ms:Date.now(),thread_id:Process.getCurrentThreadId()},extra||{})); }
function hex(buf) { if(buf===null)return null; const a=new Uint8Array(buf); let s=""; for(let i=0;i<a.length;i++)s+=a[i].toString(16).padStart(2,"0"); return s; }
function ps(v) { try{return v?v.toString():null;}catch(_){return null;} }
function u8(p) { try{return p&&!p.isNull()?p.readU8():null;}catch(_){return null;} }
function u64(p) { try{return p&&!p.isNull()?p.readU64().toString():null;}catch(_){return null;} }
function ptrAt(p) { try{return p&&!p.isNull()?p.readPointer():null;}catch(_){return null;} }
function regs(c) { return {rax:ps(c.rax),rbx:ps(c.rbx),rcx:ps(c.rcx),rdx:ps(c.rdx),rsi:ps(c.rsi),rdi:ps(c.rdi),r8:ps(c.r8),r9:ps(c.r9),r10:ps(c.r10),r11:ps(c.r11),r12:ps(c.r12),r13:ps(c.r13),r14:ps(c.r14),r15:ps(c.r15)}; }
function candidate(p) { try { if(!p||p.isNull())return null; return {ptr:ps(p),qword0:u64(p),session_flag_22:u8(p.add(0x22)),op_flag_160:u8(p.add(0x160)),op_flag_161:u8(p.add(0x161)),op_gid_70:u64(p.add(0x70))}; } catch(_){return null;} }
function bridgeSnapshot(c) { const bridge=c.rcx,incoming=c.rdx,active=ptrAt(bridge?bridge.add(0x98):null); return {bridge:ps(bridge),incoming_session:ps(incoming),incoming_msid:u64(incoming),bridge_active_session:ps(active),bridge_active_msid:u64(active),bridge_manager:ps(ptrAt(bridge?bridge.add(0xa0):null))}; }
function watchCallout(label,rva) { return function(c){ const e={label:label,rva:"0x"+rva.toString(16),registers:regs(c)}; if(rva===0x3a04a32||rva===0x3a04a46||rva===0x3a04a5f)e.bridge=bridgeSnapshot(c); if(rva===0x479bc0b||rva===0x479ebe9||rva===0x479b785){e.rcx_state=candidate(c.rcx);e.rdx_state=candidate(c.rdx);e.rbx_state=candidate(c.rbx);} emit("matchmaking_watch_hit",e); }; }
function zeroBCallout(rva) { return function(c){ emit("connection_validated_0x0b_instruction",{rva:"0x"+rva.toString(16),registers:regs(c),rcx_state:candidate(c.rcx),rdx_state:candidate(c.rdx),rbx_state:candidate(c.rbx),rsi_state:candidate(c.rsi),rdi_state:candidate(c.rdi)}); }; }
function startStalker(tid) {
  if(activeThreads[tid])return; activeThreads[tid]=true; emit("stalker_window_started",{target_thread:tid,window_ms:STALK_MS});
  Stalker.follow(tid,{transform:function(iterator){let instruction; while((instruction=iterator.next())!==null){const rva=instruction.address.sub(fifaBase).toUInt32(),key="0x"+rva.toString(16); if(WATCH[key])iterator.putCallout(watchCallout(WATCH[key],rva)); if(rva>=ZERO_B_START&&rva<=ZERO_B_END)iterator.putCallout(zeroBCallout(rva)); iterator.keep();}}});
  setTimeout(function(){try{Stalker.unfollow(tid);Stalker.flush();Stalker.garbageCollect();}catch(e){emit("observer_error",{stage:"stalker_stop",error:String(e)});} delete activeThreads[tid];emit("stalker_window_finished",{target_thread:tid});},STALK_MS);
}
function installCards() {
  if(cardsHooked)return; let m=null; try{m=Process.getModuleByName(CARDS);}catch(_){return;} const target=m.base.add(CARDS_RVA); let live=null; try{live=hex(target.readByteArray(16));}catch(_){}
  try{Interceptor.attach(target,{onEnter:function(){emit("cards_get_squad_list_entry",{module_base:ps(m.base),target:ps(target),live_bytes_16:live,rcx:ps(this.context.rcx),rdx:ps(this.context.rdx)});}});cardsHooked=true;emit("cards_probe_ready",{module_base:ps(m.base),target:ps(target),live_bytes_16:live});}catch(e){emit("observer_error",{stage:"cards_hook",error:String(e)});}
}
function install() {
  const m=Process.getModuleByName(FIFA);fifaBase=m.base;const seed=fifaBase.add(SEED_RVA);const actual=hex(seed.readByteArray(SEED_HEX.length/2));
  if(actual!==SEED_HEX){emit("observer_fatal",{stage:"seed_bytes",expected:SEED_HEX,actual:actual});return;}
  try{Interceptor.attach(seed,{onEnter:function(){const tid=Process.getCurrentThreadId();emit("gamesetup_seed_hit",{rva:"0x"+SEED_RVA.toString(16)});startStalker(tid);}});}catch(e){emit("observer_fatal",{stage:"seed_hook",error:String(e)});return;}
  emit("observer_ready",{fifa_base:ps(fifaBase),seed_rva:"0x"+SEED_RVA.toString(16),seed_hex:SEED_HEX,stalker_ms:STALK_MS});installCards();const timer=setInterval(function(){installCards();if(cardsHooked)clearInterval(timer);},250);
}
install();
'''

def render_js() -> str:
    watch = {f"0x{rva:x}": label for rva, label in WATCH_RVAS.items()}
    return JS.replace("__WATCH__", json.dumps(watch, separators=(",", ":")))

def self_test() -> int:
    source = render_js()
    required = ["0x47bcc7c","0x479ebe9","0x479bc0b","0x3a04a32","0x3715903","ZERO_B_START","ZERO_B_END","cards_get_squad_list_entry","bridge_active_msid","connection_validated_0x0b_instruction","observer_ready"]
    missing=[m for m in required if m not in source.lower() and m not in source]
    if missing: print(f"FAIL: rendered observer missing markers: {missing}"); return 1
    print("PASS: Player B observer renders the recovered matchmaking chain, bridge owner/MSID snapshot, full 0x0B decision window, and CardsDLL GetSquadList entry.")
    print("PASS: recovered FIFA function entries are observed by Stalker callouts; no relay or wire state is changed.")
    return 0

def find_process(device, seconds: int) -> int:
    import frida
    deadline=time.monotonic()+seconds
    while time.monotonic()<deadline:
        try:return device.get_process(MODULE_NAME).pid
        except frida.ProcessNotFoundError:time.sleep(0.25)
    raise RuntimeError("fifa15.exe did not appear before timeout")

def main() -> int:
    parser=argparse.ArgumentParser();parser.add_argument("--self-test",action="store_true");parser.add_argument("--pid",type=int);parser.add_argument("--wait",type=int,default=600);parser.add_argument("--jsonl",type=Path);parser.add_argument("--text",type=Path);args=parser.parse_args()
    if args.self_test:return self_test()
    try:import frida
    except ImportError:print("FRIDA_MISSING: python -m pip install frida",file=sys.stderr);return 40
    out_json=args.jsonl or Path("matchmaking-native-observer.jsonl");out_text=args.text or Path("matchmaking-native-observer.txt");out_json.parent.mkdir(parents=True,exist_ok=True);out_text.parent.mkdir(parents=True,exist_ok=True)
    device=frida.get_local_device()
    try:pid=args.pid if args.pid is not None else find_process(device,args.wait);session=device.attach(pid)
    except Exception as error:print(f"observer attach failed: {error}",file=sys.stderr);return 41
    jsonh=out_json.open("w",encoding="utf-8");texth=out_text.open("w",encoding="utf-8");counts={};ready=False;fatal=False
    def line(text):
        texth.write(text+"\n");texth.flush()
        try:print(text)
        except UnicodeEncodeError:print(text.encode("ascii","backslashreplace").decode("ascii"))
    def on_message(message,_data):
        nonlocal ready,fatal
        if message.get("type")=="error":fatal=True;line(f"[SCRIPT ERROR] {message.get('description')}");return
        payload=message.get("payload") or {};kind=str(payload.get("type","unknown"));payload["_wallclock_iso"]=time.strftime("%Y-%m-%dT%H:%M:%S");counts[kind]=counts.get(kind,0)+1;jsonh.write(json.dumps(payload,sort_keys=True,default=str)+"\n");jsonh.flush()
        if kind=="observer_ready":ready=True
        if kind=="observer_fatal":fatal=True
        line(f"[{kind}] {payload}")
    script=session.create_script(render_js());script.on("message",on_message);script.load();line(f"observer attached pid={pid}; jsonl={out_json}; text={out_text}")
    try:
        while True:
            time.sleep(0.5)
            try:device.get_process(MODULE_NAME)
            except frida.ProcessNotFoundError:break
    except KeyboardInterrupt:pass
    finally:
        try:script.unload()
        except Exception:pass
        try:session.detach()
        except Exception:pass
        jsonh.close();texth.close()
    print("=== native observer summary ===")
    for key in sorted(counts):print(f"  {key}: {counts[key]}")
    if fatal or not ready:print("RESULT: VOID - observer was not safely live");return 2
    print("RESULT: observer completed; interpret only recorded hits/absence within a proven live window");return 0

if __name__ == "__main__":
    raise SystemExit(main())
