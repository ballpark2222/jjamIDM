#!/usr/bin/env python3
"""Repro: send media.probe + media.enqueue for the failing YouTube URL
straight to the packaged engine over NDJSON stdin/stdout."""
import json, os, subprocess, sys, threading, time

ENGINE = r"C:\Users\myhome\Documents\AI_Class\freedm\apps\engine-host\bin\jjamidm-engine-host.exe"
TMP = r"C:\Users\myhome\Documents\AI_Class\freedm\.repro-tmp"
os.makedirs(TMP, exist_ok=True)

eng = subprocess.Popen(
    [ENGINE, "--temp-root", TMP, "--data-dir", TMP],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT, bufsize=1)

frames = []
def reader():
    for raw in eng.stdout:
        line = raw.decode("utf-8", "replace").rstrip()
        if not line:
            continue
        try:
            frames.append(json.loads(line))
            print("<<", line[:500], flush=True)
        except json.JSONDecodeError:
            print("<<RAW", line[:300], flush=True)

threading.Thread(target=reader, daemon=True).start()

def send(obj):
    s = json.dumps(obj)
    print(">>", s[:300], flush=True)
    eng.stdin.write((s + "\n").encode("utf-8"))
    eng.stdin.flush()

def wait_for(pred, secs):
    deadline = time.time() + secs
    while time.time() < deadline:
        hit = next((f for f in frames if pred(f)), None)
        if hit:
            return hit
        time.sleep(0.3)
    return None

send({"jsonrpc": "2.0", "id": 1, "method": "media.probe",
      "params": {"pageUrl": "https://www.youtube.com/watch?v=9IyTENQOL0U"}})

result = wait_for(lambda f: f.get("id") == 1, 120)
if result is None:
    print("PROBE TIMEOUT"); eng.kill(); sys.exit(2)

p = result.get("result") or {}
fmts = p.get("formats") or []
vid = next((f for f in fmts if f.get("hasVideo") and f.get("height")), None)
print("PROBE done - formats:", len(fmts),
      "| picked:", vid and (vid.get("formatId"), vid.get("height")))

send({"jsonrpc": "2.0", "id": 2, "method": "task.subscribeEvents",
      "params": {"taskId": "*"}})

params = {
    "pageUrl": "https://www.youtube.com/watch?v=9IyTENQOL0U",
    "targetDirectory": TMP,
    "headers": {"cookie": "SID=x", "user-agent": "Mozilla/5.0",
                "referer": "https://www.youtube.com/"},
}
if vid:
    params["videoFormatId"] = vid.get("formatId")
send({"jsonrpc": "2.0", "id": 3, "method": "media.enqueue", "params": params})

ack = wait_for(lambda f: f.get("id") == 3, 15)
new_id = ((ack or {}).get("result") or {}).get("taskId")
print("enqueued task:", new_id)

final = wait_for(
    lambda f: f.get("method") == "media.event"
    and ((f.get("params") or {}).get("task") or {}).get("id") == new_id
    and ((f.get("params") or {}).get("task") or {}).get("status")
    in ("failed", "completed"), 180)

if final:
    t = (final.get("params") or {}).get("task") or {}
    print("FINAL:", t.get("status"),
          "| lastError:", t.get("lastError"),
          "| detail:", (t.get("metadata") or {}).get("lastErrorDetail"),
          "| out:", (t.get("metadata") or {}).get("outputPath"))
else:
    print("NO TERMINAL EVENT in 90s - task still running")
    for f in frames[-6:]:
        print("  tail:", json.dumps(f)[:300])

eng.kill()
