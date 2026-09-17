#!/usr/bin/env python3
"""E2E: fixture server -> freedm_native_host -> real engine-host (Dart)
-> bytes on disk. Proves cold launch, protocol bridging and task.event
streaming end to end.

Run from the repo root:
  python native-host/test/e2e_engine.py <host-exe> <dart-exe>
"""
import hashlib
import json
import os
import struct
import subprocess
import sys
import tempfile
import threading
import time

HOST_EXE, DART = sys.argv[1], sys.argv[2]
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def frame(msg: dict) -> bytes:
    body = json.dumps(msg).encode()
    return struct.pack("<I", len(body)) + body


def read_frame(proc, timeout=90) -> dict:
    out = {}
    def _read():
        raw = proc.stdout.read(4)
        if len(raw) < 4:
            out["err"] = "eof"
            return
        n = struct.unpack("<I", raw)[0]
        out["msg"] = json.loads(proc.stdout.read(n))
    t = threading.Thread(target=_read, daemon=True)
    t.start(); t.join(timeout)
    if "msg" not in out:
        raise TimeoutError(f"no frame in {timeout}s: {out}")
    return out["msg"]


def fixture_byte(i: int, seed: int = 7) -> int:
    return (i * seed + i) & 0xFF


# 1. fixture server ----------------------------------------------------
srv = subprocess.Popen(
    [DART, "bin/serve.dart"], cwd=os.path.join(ROOT, "test-server"),
    stdout=subprocess.PIPE, text=True)
port = None
for line in srv.stdout:
    if line.startswith("PORT "):
        port = int(line.split()[1]); break
assert port, "fixture server did not report a port"
print(f"fixture server on :{port}")

# 2. host config --------------------------------------------------------
dl = tempfile.mkdtemp(prefix="freedm-e2e-out")
tmp = tempfile.mkdtemp(prefix="freedm-e2e-tmp")
cfg_path = os.path.join(tmp, "native-host.json")
with open(cfg_path, "w") as f:
    json.dump({
        "allowedOrigins": ["chrome-extension://dev-self-test/"],
        "engineCommand": [DART, "bin/main.dart",
                          "--temp-root", tmp],
        "engineCwd": os.path.join(ROOT, "apps", "engine-host"),
        "downloadDir": dl,
    }, f)

env = dict(os.environ, FREEDM_NATIVE_HOST_CONFIG=cfg_path)
host = subprocess.Popen(
    [HOST_EXE, "--self-test"], stdin=subprocess.PIPE,
    stdout=subprocess.PIPE, env=env)

def send(m):
    host.stdin.write(frame(m)); host.stdin.flush()

def msg(rid, command, payload=None):
    return {"protocol": 1, "requestId": rid, "source": "extension",
            "extensionVersion": "0.1.0", "command": command,
            "payload": payload or {}}

failures = []
def check(name, cond, ctx=""):
    print(("PASS" if cond else "FAIL"), name, ctx)
    if not cond:
        failures.append(name)

try:
    send(msg(1, "ping"))
    r = read_frame(host)
    check("ping reaches engine (cold launch)", r.get("ok") and
          r["result"].get("engineReachable") is True, r)

    url = f"http://127.0.0.1:{port}/file-range"
    send(msg(2, "download", {"url": url,
                             "suggestedFilename": "e2e.bin"}))
    r = read_frame(host)
    check("download accepted", r.get("ok") and r["result"].get("taskId"),
          r)
    task_id = r["result"]["taskId"]

    # 3. stream task events until completed ------------------------------
    saw_progress = saw_completed = False
    deadline = time.time() + 120
    while time.time() < deadline and not saw_completed:
        r = read_frame(host, timeout=60)
        ev = (r.get("event") or {}).get("params", {})
        if ev.get("type") == "progress" and not saw_progress:
            saw_progress = True
            check("progress events stream", True,
                  f"recv={ev.get('receivedBytes')}")
        if ev.get("type") == "completed":
            saw_completed = True
        if ev.get("type") == "failed":
            check("task completed", False, ev)
            break
    check("task completed", saw_completed)

    out = os.path.join(dl, "e2e.bin")
    n = 1 << 20
    expected = hashlib.sha256(
        bytes(fixture_byte(i) for i in range(n))).hexdigest()
    with open(out, "rb") as f:
        actual = hashlib.sha256(f.read()).hexdigest()
    check("output sha256 matches fixture", actual == expected)

    send(msg(3, "status", {"taskId": task_id}))
    r = read_frame(host)
    check("status reports task", r.get("ok") is True, r)
finally:
    host.kill(); srv.kill()

print()
if failures:
    print(f"{len(failures)} FAILURES: {failures}")
    sys.exit(1)
print("E2E passed: browser -> host -> engine -> disk")
