#!/usr/bin/env python3
"""End-to-end tests for egress_proxy + sandbox_tui proxy mode. Run from repo root:
   python3 tests/proxy_test.py        (needs src/egress_proxy and src/sandbox_tui built)"""
import json, os, socket, stat, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
MOCK_PORT, PROXY_PORT = 18901, 18902
TOKEN = "CANARY_gw_secret_90210"
ENV_CANARY = "CANARY_env_secret_31337"
fails = []

def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else "  -> " + str(detail)[:300]))
    if not cond:
        fails.append(name)

def raw(data, port=PROXY_PORT, read_all=True, timeout=5):
    s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    s.sendall(data if isinstance(data, bytes) else data.encode())
    buf = b""
    try:
        while True:
            c = s.recv(65536)
            if not c: break
            buf += c
            if not read_all: break
    except socket.timeout:
        pass
    s.close()
    return buf

def status(resp):
    try: return int(resp.split(b" ", 2)[1])
    except Exception: return -1

def wait_port(port):
    for _ in range(100):
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.2).close(); return True
        except OSError: time.sleep(0.1)
    return False

tmp = tempfile.mkdtemp()
rules_path = os.path.join(tmp, "rules.json")
rules = {
    "listen": "127.0.0.1:%d" % PROXY_PORT,
    "allow_domains": ["127.0.0.1"],
    "allow_ports": [MOCK_PORT],
    "gateways": {"mock": {"upstream": "http://127.0.0.1:%d" % MOCK_PORT,
                          "inject": {"Authorization": "Bearer " + TOKEN},
                          "methods": ["GET", "POST"], "max_body": 100, "max_response": 1_000_000}},
}
with open(rules_path, "w") as f: json.dump(rules, f)

# A. refuses a group/world-readable rules file
os.chmod(rules_path, 0o644)
r = subprocess.run([os.path.join(SRC, "egress_proxy"), rules_path], capture_output=True, text=True, timeout=10)
check("A refuses mode 644 rules file", r.returncode != 0 and "mode 600" in (r.stdout + r.stderr), r.stderr)
os.chmod(rules_path, 0o600)

mock = subprocess.Popen([sys.executable, os.path.join(ROOT, "tests", "mock_upstream.py"), str(MOCK_PORT), TOKEN])
proxy_log = os.path.join(tmp, "proxy.log")
proxy = subprocess.Popen([os.path.join(SRC, "egress_proxy"), rules_path], stderr=open(proxy_log, "w"))
try:
    assert wait_port(MOCK_PORT) and wait_port(PROXY_PORT), "servers did not start"

    # B/C/D gateway basics
    b = raw("GET /gw HTTP/1.1\r\nHost: x\r\n\r\n")
    check("B gateway list shows alias, not secret", status(b) == 200 and b"mock" in b and TOKEN.encode() not in b, b)
    c = raw("GET /gw/mock/ok HTTP/1.1\r\nHost: x\r\n\r\n")
    check("C injected credential accepted by upstream", status(c) == 200 and c.endswith(b"authorized"), c)
    d = raw("GET /gw/mock/ok HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer evil\r\n\r\n")
    check("D client-forged Authorization overridden", status(d) == 200 and d.endswith(b"authorized"), d)
    p = raw("POST /gw/mock/x HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello")
    check("D2 POST body forwarded with injection", status(p) == 200 and p.endswith(b"len=5"), p)

    # E rejections
    check("E1 unknown alias 404", status(raw("GET /gw/nope/ok HTTP/1.1\r\n\r\n")) == 404)
    check("E2 disallowed method 405", status(raw("DELETE /gw/mock/ok HTTP/1.1\r\n\r\n")) == 405)
    check("E3 '..' path 400", status(raw("GET /gw/mock/../ok HTTP/1.1\r\n\r\n")) == 400)
    check("E4 encoded traversal 400", status(raw("GET /gw/mock/%2e%2e/ok HTTP/1.1\r\n\r\n")) == 400)
    check("E5 CRLF in path 400", status(raw("GET /gw/mock/ok%0d%0aX-Evil:1 HTTP/1.1\r\n\r\n")) == 400)
    check("E6 oversize body 413", status(raw("POST /gw/mock/x HTTP/1.1\r\nContent-Length: 101\r\n\r\n" + "a" * 101)) == 413)
    check("E7 chunked rejected 400", status(raw("POST /gw/mock/x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")) == 400)
    check("E8 absolute-URI request 403", status(raw("GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n")) == 403)

    # F/G redaction + response cap
    f = raw("GET /gw/mock/echo HTTP/1.1\r\n\r\n")
    check("F upstream echo of secret is redacted", b"[REDACTED]" in f and TOKEN.encode() not in f, f)
    g = raw("GET /gw/mock/big HTTP/1.1\r\n\r\n")
    check("G oversize upstream response -> 502", status(g) == 502, g[:80])

    # I CONNECT policy
    check("I1 CONNECT non-allowlisted host 403", status(raw("CONNECT example.com:443 HTTP/1.1\r\n\r\n")) == 403)
    check("I2 CONNECT disallowed port 403", status(raw("CONNECT 127.0.0.1:22 HTTP/1.1\r\n\r\n")) == 403)
    t = raw("CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n" % MOCK_PORT, read_all=False)
    check("I3 CONNECT allowlisted -> 200", status(t) == 200, t)
    s = socket.create_connection(("127.0.0.1", PROXY_PORT), timeout=5)
    s.sendall(("CONNECT 127.0.0.1:%d HTTP/1.1\r\n\r\n" % MOCK_PORT).encode()); s.recv(4096)
    s.sendall(b"GET /ok HTTP/1.1\r\nHost: m\r\nConnection: close\r\n\r\n")
    tun = b""
    try:
        while True:
            ch = s.recv(4096)
            if not ch: break
            tun += ch
    except socket.timeout: pass
    s.close()
    check("I4 tunnel works but gets NO injection (401)", status(tun) == 401, tun)

    # K TUI integration
    tui_env = dict(os.environ, SANDBOX_PROXY="127.0.0.1:%d" % PROXY_PORT, CANARY_SECRET=ENV_CANARY)
    script = "\n".join([
        ":net proxy", ":gateways",
        "import os, urllib.request, socket",
        "print('envcanary=', os.environ.get('CANARY_SECRET'))",
        "print('gw=', urllib.request.urlopen(os.environ['SANDBOX_GATEWAY'] + '/mock/ok').read().decode())",
        "try:",
        "    socket.create_connection(('127.0.0.1', %d), 2)" % MOCK_PORT,
        "    print('direct=CONNECTED')",
        "except OSError as e:",
        "    print('direct=blocked')",
        ".",
        ":lang js",
        "fetch(process.env.SANDBOX_GATEWAY + '/mock/ok').then(r => r.text()).then(t => console.log('jsgw=' + t));",
        ".",
        ":net off", ":lang python",
        "import os, urllib.request",
        "try:",
        "    urllib.request.urlopen('http://127.0.0.1:%d/gw/mock/ok', timeout=2)" % PROXY_PORT,
        "    print('off=CONNECTED')",
        "except Exception:",
        "    print('off=blocked')",
        ".", ":quit", ""])
    work = tempfile.mkdtemp()
    r = subprocess.run([os.path.join(SRC, "sandbox_tui")], input=script, text=True, capture_output=True,
                       cwd=work, env=tui_env, timeout=60)
    out = r.stdout
    check("K1 :gateways lists mock", '"mock"' in out, out[-400:])
    check("K2 python reaches gateway, gets authorized", "gw= authorized" in out, out[-600:])
    check("K3 TUI env var NOT visible to snippet (env -i)", "envcanary= None" in out, out[-600:])
    check("K4 direct connect to non-proxy host blocked", "direct=blocked" in out, out[-600:])
    check("K5 js reaches gateway", "jsgw=authorized" in out, out[-600:])
    check("K6 :net off blocks even the proxy", "off=blocked" in out, out[-600:])
    check("K7 no secret in TUI output", TOKEN not in out and ENV_CANARY not in out)

    # J logs
    time.sleep(0.3)
    log = open(proxy_log).read()
    check("J1 secret never in proxy log", TOKEN not in log and "evil" not in log, log[-300:])
    check("J2 proxy logs gateway activity", "GW mock" in log, log[-300:])
finally:
    proxy.terminate(); mock.terminate()
    proxy.wait(); mock.wait()

print("\n%d failure(s)" % len(fails))
sys.exit(1 if fails else 0)
