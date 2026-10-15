#!/usr/bin/env python3
"""Tests for run hardening: process-group kill, resource limits, sessions, one-shot JSON CLI,
live streaming, quota warning.  Run from repo root after building src/sandbox_tui."""
import json, os, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TUI = os.path.join(ROOT, "src", "sandbox_tui")
fails = []

def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else "  -> " + str(detail)[:300]))
    if not cond: fails.append(name)

def run(lang, code, d, timeout=10, session=None, net="off", expect_rc=0):
    args = [TUI, "--run", lang, "--timeout", str(timeout), "--net", net, "--dir", d]
    if session: args += ["--session", session]
    r = subprocess.run(args, input=code, capture_output=True, text=True, timeout=timeout + 30)
    if r.returncode != expect_rc:
        return {"_rc": r.returncode, "_err": r.stderr, "_out": r.stdout}
    return json.loads(r.stdout) if expect_rc == 0 else {"_rc": r.returncode, "_err": r.stderr}

def pgrep(pat):
    return subprocess.run(["pgrep", "-f", pat], capture_output=True, text=True).stdout.split()

d = tempfile.mkdtemp()

# --- one-shot JSON
r = run("python", "print(6*7)\n", d)
check("J1 --run ok", r.get("status") == "ok" and r["output"].strip() == "42" and r["exit_code"] == 0, r)
r = run("python", "raise SystemExit(3)\n", d)
check("J2 --run error status + exit code", r.get("status") == "error" and r["exit_code"] == 3, r)
r = run("python", "import time; time.sleep(30)\n", d, timeout=2)
check("J3 --run timeout flagged explicitly", r.get("status") == "timeout" and r["timed_out"] is True and 1.9 < r["secs"] < 4, r)
check("J4 bad language rejected (rc 2)", run("ruby", "x", d, expect_rc=2)["_rc"] == 2)
check("J5 bad session name rejected (rc 2)", run("python", "x", d, session="../evil", expect_rc=2)["_rc"] == 2)
check("J6 --net on refused in one-shot (rc 2)", run("python", "x", d, net="on", expect_rc=2)["_rc"] == 2)
r = run("python", "x = 1\n" * 1, d, timeout=700, expect_rc=2)
check("J7 timeout > 600 rejected (rc 2)", r.get("_rc") == 2, r)
big = subprocess.run([TUI, "--run", "python", "--dir", d], input="#" * 250_000, capture_output=True, text=True)
check("J8 oversized code rejected (rc 2)", big.returncode == 2, big.stderr)

# --- process-group kill
run("python", "import subprocess, time\nsubprocess.Popen(['sleep','3171'])\ntime.sleep(60)\n", d, timeout=2)
time.sleep(0.5)
check("K1 child of timed-out run is killed", pgrep("sleep 3171") == [], pgrep("sleep 3171"))
run("python", "import subprocess\nsubprocess.Popen(['sleep','3172'])\nprint('parent exits')\n", d)
time.sleep(0.5)
check("K2 background child left by a finished run is reaped", pgrep("sleep 3172") == [], pgrep("sleep 3172"))

# --- limits
r = run("python", "f = open('big.bin','wb')\nf.write(b'x'*(60*1024*1024))\nf.flush()\n", d)
big_file = os.path.join(d, "sessions", "default", "big.bin")
check("L1 file-size limit stops a 60 MB write", r.get("status") == "error" and
      (not os.path.exists(big_file) or os.path.getsize(big_file) <= 50 * 1024 * 1024 + 4096), r)
r = run("python", "fs=[open('/dev/null') for _ in range(400)]\n", d)
check("L2 open-file limit", r.get("status") == "error" and "Too many open files" in r["output"], r)
r = run("python", "b = bytearray(3*1024*1024*1024)\n", d)
check("L3 address-space limit gives MemoryError", r.get("status") == "error" and "MemoryError" in r["output"], r)
r = run("js", "const a=[]; for(;;) a.push(new Array(1e6).fill(1));\n", d, timeout=20)
check("L4 node V8 heap cap stops runaway allocation", r.get("status") == "error" and r["timed_out"] is False, r)
r = run("python", "import os\nprint(os.environ.get('HOME'))\nprint(sorted(os.environ))\n", d, session="envs")
check("L5 scrubbed env: only PATH/HOME/LANG(+runtime vars)", r.get("status") == "ok" and "sessions/envs" in r["output"] and
      "USER" not in r["output"] and "TERM" not in r["output"], r)

# --- sessions
run("sql", "create table t(a); insert into t values (7);\n", d, session="alpha")
r = run("sql", "select a from t;\n", d, session="alpha")
check("S1 session db persists across runs", r.get("status") == "ok" and "7" in r["output"], r)
r = run("sql", "select a from t;\n", d, session="beta")
check("S2 other session cannot see it", r.get("status") == "error" and "no such table" in r["output"], r)
run("python", "open('note.txt','w').write('hi')\n", d, session="beta")
ls = json.loads(subprocess.run([TUI, "--sessions"], capture_output=True, text=True, env=dict(os.environ, SANDBOX_DIR=d)).stdout)
names = {s["name"] for s in ls["sessions"]}
check("S3 --sessions lists sessions", {"alpha", "beta", "default"} <= names, ls)
r = run("python", "import os\nprint(os.getcwd())\n", d, session="alpha")
check("S4 cwd is the session dir", r["output"].strip().endswith("sessions/alpha"), r)

# --- quota warning (soft)
code = "for i in range(3):\n    open('f%d.bin' % i, 'wb').write(b'x' * (20*1024*1024))\n"
r = run("python", code, d, session="quota")
check("Q1 soft quota warning after 60 MB in a session", r.get("status") == "ok" and "over its 50 MB quota" in r.get("quota_warning", ""), r)

# --- live streaming through the REPL
p = subprocess.Popen([TUI], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                     env=dict(os.environ, SANDBOX_DIR=tempfile.mkdtemp()), bufsize=0)
p.stdin.write(b"import time\nprint('FIRST', flush=True)\ntime.sleep(2)\nprint('SECOND', flush=True)\n.\n:quit\n")
p.stdin.flush()
seen = {}
buf = b""
t0 = time.time()
import select
while time.time() - t0 < 15:
    rl, _, _ = select.select([p.stdout], [], [], 0.2)
    if rl:
        chunk = os.read(p.stdout.fileno(), 4096)
        if not chunk: break
        buf += chunk
        for tag in (b"FIRST", b"SECOND"):
            if tag in buf and tag not in seen: seen[tag] = time.time() - t0
p.wait(timeout=10)
check("T1 output streams live (FIRST arrives >1s before SECOND)",
      b"FIRST" in seen and b"SECOND" in seen and seen[b"SECOND"] - seen[b"FIRST"] > 1.0, seen)

print("\n%d failure(s)" % len(fails))
sys.exit(1 if fails else 0)
