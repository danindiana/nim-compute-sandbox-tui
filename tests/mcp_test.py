#!/usr/bin/env python3
"""MCP stdio tests. Default: --local runner (tests/CI). With --container NAME [--exec-path P] [--workdir D] [--proxy H:P] [--example-gateway]:
runs the same checks through `docker exec` against a real sandbox container."""
import json, os, socket, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
MOCK_PORT, PROXY_PORT = 18961, 18962
TOKEN = "CANARY_mcp_secret_77001"
fails = []
all_text = []   # every byte the server ever sent us, to scan for the secret

def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else "  -> " + str(detail)[:300]))
    if not cond: fails.append(name)

def wait_port(port):
    for _ in range(100):
        try: socket.create_connection(("127.0.0.1", port), timeout=0.2).close(); return True
        except OSError: time.sleep(0.1)
    return False

args = sys.argv[1:]
container = args[args.index("--container") + 1] if "--container" in args else None
tmp = tempfile.mkdtemp()
rules_path = os.path.join(tmp, "rules.json")
json.dump({"listen": "127.0.0.1:%d" % PROXY_PORT, "allow_domains": ["127.0.0.1"], "allow_ports": [MOCK_PORT],
           "gateways": {"mock": {"upstream": "http://127.0.0.1:%d" % MOCK_PORT,
                                 "inject": {"Authorization": "Bearer " + TOKEN}}}}, open(rules_path, "w"))
os.chmod(rules_path, 0o600)
mock = subprocess.Popen([sys.executable, os.path.join(ROOT, "tests", "mock_upstream.py"), str(MOCK_PORT), TOKEN])
proxy = subprocess.Popen([os.path.join(SRC, "egress_proxy"), rules_path], stderr=subprocess.DEVNULL)
if container:
    cmd = [os.path.join(SRC, "sandbox_mcp"), "--container", container, "--proxy", args[args.index("--proxy") + 1] if "--proxy" in args else "172.29.0.2:8899"] \
        + (["--exec-path", args[args.index("--exec-path") + 1]] if "--exec-path" in args else []) + (["--workdir", args[args.index("--workdir") + 1]] if "--workdir" in args else []) + ["--max-timeout", "20"]
else:
    cmd = [os.path.join(SRC, "sandbox_mcp"), "--local", "--bin", os.path.join(SRC, "sandbox_tui"),
           "--dir", os.path.join(tmp, "runs"), "--proxy", "127.0.0.1:%d" % PROXY_PORT, "--max-timeout", "20"]
srv = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
_id = [0]

def send(obj):
    srv.stdin.write((obj if isinstance(obj, str) else json.dumps(obj)) + "\n"); srv.stdin.flush()

def rpc(method, params=None, raw_id=None):
    _id[0] += 1
    send({"jsonrpc": "2.0", "id": _id[0] if raw_id is None else raw_id, "method": method, **({"params": params} if params is not None else {})})
    line = srv.stdout.readline()
    all_text.append(line)
    return json.loads(line)

def tool(name, **a):
    r = rpc("tools/call", {"name": name, "arguments": a})
    res = r.get("result", {})
    text = res.get("content", [{}])[0].get("text", "") if res else r.get("error", {}).get("message", "")
    return res, text, r

try:
    assert wait_port(MOCK_PORT) and wait_port(PROXY_PORT), "mock/proxy did not start"
    r = rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}})
    check("M1 initialize: serverInfo + tools capability", r["result"]["serverInfo"]["name"] == "sandbox-mcp" and "tools" in r["result"]["capabilities"], r)
    send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    r = rpc("ping")
    check("M2 notification gets no response; ping answered next", r.get("result") == {} and r["id"] == _id[0], r)
    r = rpc("tools/list")
    names = {t["name"] for t in r["result"]["tools"]}
    check("M3 tools/list has the 3 tools with schemas", names == {"run_code", "list_gateways", "list_sessions"} and
          all("inputSchema" in t for t in r["result"]["tools"]), r)

    res, text, _ = tool("run_code", lang="python", code="print(6*7)")
    check("R1 run_code ok", "status: ok" in text and "\n42" in text and res["isError"] is False, text)
    res, text, _ = tool("run_code", lang="python", code="raise ValueError('boom')")
    check("R2 code error reported as result (isError false) with traceback", "status: error" in text and "ValueError: boom" in text and res["isError"] is False, text)
    res, text, _ = tool("run_code", lang="python", code="import time; time.sleep(30)", timeout_s=2)
    check("R3 timeout reported", "status: timeout" in text and "TIMED OUT after 2s" in text, text)
    res, text, _ = tool("run_code", lang="js", code="console.log(1+2)")
    check("R4 js", "status: ok" in text and "\n3" in text, text)
    tool("run_code", lang="sql", code="create table t(a); insert into t values (9);", session="mcp1")
    res, text, _ = tool("run_code", lang="sql", code="select a from t;", session="mcp1")
    check("R5 sql session persists across calls", "status: ok" in text and "9" in text, text)
    res, text, _ = tool("list_sessions")
    check("R6 list_sessions shows it", "mcp1" in text and res["isError"] is False, text)

    res, text, _ = tool("run_code", lang="ruby", code="puts 1")
    check("V1 bad lang -> isError", res["isError"] is True, text)
    res, text, _ = tool("run_code", lang="python", code="print(1)", net="on")
    check("V2 net=on refused", res["isError"] is True and "'on' is not available" in text, text)
    res, text, _ = tool("run_code", lang="python", code="x" * 100_001)
    check("V3 oversized code refused", res["isError"] is True, text)
    res, text, _ = tool("run_code", lang="python", code="print(1)", timeout_s=21)
    check("V4 timeout above --max-timeout refused", res["isError"] is True, text)
    res, text, _ = tool("run_code", lang="python", code="print(1)", session="x; touch /tmp/pwned")
    check("V5 session name injection refused", res["isError"] is True and not os.path.exists("/tmp/pwned"), text)
    res, text, _ = tool("run_code", lang="python", code="")
    check("V6 empty code refused", res["isError"] is True, text)
    r = rpc("tools/call", {"name": "rm_rf", "arguments": {}})
    check("V7 unknown tool -> JSON-RPC error -32602", r.get("error", {}).get("code") == -32602, r)
    r = rpc("does/not/exist")
    check("V8 unknown method -> -32601", r.get("error", {}).get("code") == -32601, r)
    srv.stdin.write("{not json\n"); srv.stdin.flush()
    line = srv.stdout.readline(); all_text.append(line)
    check("V9 malformed JSON -> -32700, server survives", json.loads(line)["error"]["code"] == -32700 and rpc("ping").get("result") == {}, line)
    r = rpc("tools/call", {"name": "run_code", "arguments": "oops"})
    check("V10 non-object arguments -> -32602", r.get("error", {}).get("code") == -32602, r)

    if not container:
        res, text, _ = tool("list_gateways")
        check("G1 list_gateways shows alias, never the secret", "mock" in text and TOKEN not in text, text)
        code = "import os, urllib.request\nprint('GW', urllib.request.urlopen(os.environ['SANDBOX_GATEWAY'] + '/mock/ok').read().decode())\n"
        res, text, _ = tool("run_code", lang="python", code=code, net="proxy")
        check("G2 net=proxy reaches gateway; credential injected by the proxy", "GW authorized" in text, text)
        res, text, _ = tool("run_code", lang="python", code="import socket\nsocket.create_connection(('1.1.1.1', 53), 2)\n", net="proxy")
        check("G3 net=proxy still blocks direct connects", "status: error" in text and "network disabled" in text, text)
    if container and "--example-gateway" in args:
        res, text, _ = tool("list_gateways")
        check("E1 isolated deployment: list_gateways shows 'example'", "example" in text and "FAKE-demo" not in text, text)
        code = "import os, urllib.request\nprint('GW', 'Example Domain' in urllib.request.urlopen(os.environ['SANDBOX_GATEWAY'] + '/example/').read().decode())\n"
        res, text, _ = tool("run_code", lang="python", code=code, net="proxy", timeout_s=20)
        check("E2 isolated deployment: gateway call works via MCP -> runner -> proxy", "GW True" in text, text)
        res, text, _ = tool("run_code", lang="python", code="import urllib.request\nurllib.request.urlopen('https://example.com', timeout=5)\n", net="off", timeout_s=15)
        check("E3 isolated deployment: net=off blocks", "status: error" in text, text)
        all_text.append("")
    check("X1 credential never appeared in any MCP response", all(TOKEN not in t and "FAKE-demo" not in t for t in all_text))
finally:
    for pr in (srv, proxy, mock):
        try: pr.terminate()
        except Exception: pass
    for pr in (proxy, mock):
        pr.wait()

print("\n%d failure(s)" % len(fails))
sys.exit(1 if fails else 0)
