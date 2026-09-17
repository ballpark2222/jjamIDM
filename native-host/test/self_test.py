#!/usr/bin/env python3
"""Native-host contract test: drives freedm_native_host.exe over the
Chrome native-messaging framing ([u32le len][json]) and asserts the
validation rules hold.

Usage: python test/self_test.py [path-to-exe]
Exit 0 on success.
"""
import json
import struct
import subprocess
import sys
import os

EXE = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(__file__), "..", "target", "x86_64-pc-windows-gnu",
    "debug", "freedm_native_host.exe")


def frame(msg: dict) -> bytes:
    body = json.dumps(msg).encode()
    return struct.pack("<I", len(body)) + body


def read_frame(proc, timeout=10) -> dict:
    proc.stdout.flush()
    import threading
    out = {}
    def _read():
        raw_len = proc.stdout.read(4)
        if len(raw_len) < 4:
            out["err"] = "eof"
            return
        n = struct.unpack("<I", raw_len)[0]
        out["msg"] = json.loads(proc.stdout.read(n))
    t = threading.Thread(target=_read, daemon=True)
    t.start()
    t.join(timeout)
    if "msg" not in out:
        raise TimeoutError(f"no frame within {timeout}s: {out}")
    return out["msg"]


def msg(rid, command, payload=None):
    return {
        "protocol": 1,
        "requestId": rid,
        "source": "extension",
        "extensionVersion": "0.1.0",
        "command": command,
        "payload": payload or {},
    }


failures = []


def check(name, cond, ctx=""):
    print(("PASS" if cond else "FAIL"), name, ctx)
    if not cond:
        failures.append(name)


# --- without --self-test and no origin arg: must refuse ---------------
p = subprocess.Popen([EXE], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
p.stdin.write(frame(msg(1, "ping")))
p.stdin.flush()
r = read_frame(p)
p.wait(timeout=5)
check("no-origin run refuses", p.returncode == 2 and r.get("ok") is False,
      f"rc={p.returncode} r={r}")

# --- self-test mode ----------------------------------------------------
p = subprocess.Popen([EXE, "--self-test"], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE)

def send(m):
    p.stdin.write(frame(m))
    p.stdin.flush()
    return read_frame(p)

r = send(msg(1, "ping"))
check("ping ok", r.get("ok") is True and r["result"]["protocol"] == 1, r)

r = send(msg(2, "download", {"url": "ftp://x/f.bin"}))
check("ftp url rejected", r.get("ok") is False and "scheme" in r["error"], r)

r = send(msg(3, "download", {
    "url": "https://example.com/f.bin",
    "suggestedFilename": "..\\evil.exe"}))
check("traversal filename rejected", r.get("ok") is False, r)

r = send(msg(4, "download", {"url": "http://x/\x00bad"}))
check("control-char url rejected", r.get("ok") is False, r)

r = send(msg(5, "exec", {"cmd": "calc"}))
check("unknown command rejected", r.get("ok") is False, r)

r = send({"protocol": 2, "requestId": 6, "source": "extension",
          "extensionVersion": "0.1.0", "command": "ping", "payload": {}})
check("protocol v2 rejected", r.get("ok") is False and "protocol" in r["error"], r)

r = send({"protocol": 1, "requestId": 7, "command": "ping", "payload": {}})
check("missing source rejected", r.get("ok") is False, r)

r = send(msg(8, "pause", {"taskId": "../../etc/passwd"}))
check("bad taskId rejected", r.get("ok") is False, r)

# oversize frame → channel must die (host exits on the length header,
# so even the body write can hit a closed pipe — that is the pass)
big = msg(9, "ping", {"pad": "x" * (2 << 20)})
try:
    p.stdin.write(frame(big))
    p.stdin.flush()
    p.stdin.write(frame(msg(10, "ping")))
    p.stdin.flush()
    r = read_frame(p, timeout=3)
    check("oversize frame kills channel", False, f"got reply {r}")
except (TimeoutError, BrokenPipeError):
    check("oversize frame kills channel", True)

p.kill()

print()
if failures:
    print(f"{len(failures)} FAILURES: {failures}")
    sys.exit(1)
print("all native-host checks passed")
