#!/usr/bin/env bash
# Verifies the isolation properties of the up.sh deployment. Exit 1 on any failure.
set -uo pipefail
R=sbx-runner; P=sbx-proxy; PROXY_IP=${PROXY_IP:-172.29.0.2}
HERMES=${HERMES_CONTAINER:-}          # optional: an existing sandbox container to check is unaffected
fail=0
pass() { echo "PASS $1"; }
bad()  { echo "FAIL $1${2:+  -> $2}"; fail=1; }
t()    { local name=$1; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else bad "$name"; fi; }
tn()   { local name=$1; shift; if "$@" >/dev/null 2>&1; then bad "$name"; else pass "$name"; fi; }
PYCONN='import socket,sys; socket.create_connection((sys.argv[1], int(sys.argv[2])), 4)'

echo "== runner network isolation (raw python, no sandbox guard)"
tn "a1 runner cannot reach the internet (1.1.1.1:53)"        docker exec $R python3 -c "$PYCONN" 1.1.1.1 53
tn "a2 runner cannot resolve names"                          docker exec $R python3 -c 'import socket; socket.gethostbyname("example.com")'
tn "a3 runner cannot reach the docker host gateway (22)"     docker exec $R python3 -c "$PYCONN" 172.29.0.1 22
tn "a4 runner cannot reach the host LAN gateway"             docker exec $R python3 -c "$PYCONN" 192.168.1.254 80
t  "a5 runner CAN reach the proxy port"                      docker exec $R python3 -c "$PYCONN" $PROXY_IP 8899
echo "== secret not reachable from the runner"
tn "b1 no rules.json mounted in runner"                      docker exec $R sh -c 'test -e /etc/sandbox-proxy/rules.json'
tn "b2 find / finds no rules*.json in runner"                docker exec $R sh -c 'find / -xdev -name "rules*.json" 2>/dev/null | grep -q .'
tn "b3 runner rootfs is read-only"                           docker exec $R sh -c 'touch /etc/x'
echo "== proxy behaviour through the isolated path"
out=$(docker exec -i $R /opt/sbx/sandbox_tui --run python --net proxy --timeout 20 <<'PY'
import os, urllib.request
print("GW", "Example Domain" in urllib.request.urlopen(os.environ["SANDBOX_GATEWAY"] + "/example/").read().decode())
try:
    urllib.request.urlopen("https://www.python.org", timeout=8); print("PYORG allowed")
except Exception as e:
    print("PYORG blocked")
print("SECRET_IN_ENV", "FAKE-demo" in str(os.environ))
PY
)
echo "$out" | grep -q 'GW True'        && pass "c1 gateway call reaches https://example.com via the proxy" || bad "c1 gateway call" "$out"
echo "$out" | grep -q 'PYORG blocked'  && pass "c2 non-allowlisted domain refused by the proxy"           || bad "c2 allowlist" "$out"
echo "$out" | grep -q 'SECRET_IN_ENV False' && pass "c3 injected value not visible to code"               || bad "c3 secret visibility" "$out"
echo "$out" | grep -q 'FAKE-demo' && bad "c4 secret leaked in output" || pass "c4 secret absent from output"
echo "== proxy exposure"
if [ -n "$HERMES" ]; then
  tn "d1 existing sandbox ($HERMES) cannot reach the proxy"  docker exec $HERMES python3 -c "$PYCONN" $PROXY_IP 8899
  t  "d2 existing sandbox still has its own network access"  docker exec $HERMES python3 -c 'import urllib.request; urllib.request.urlopen("https://example.com", timeout=8)'
  docker inspect $HERMES --format '{{json .NetworkSettings.Networks}}' | grep -q sbx-iso && bad "d3 existing sandbox untouched" || pass "d3 existing sandbox not attached to sbx-iso"
fi
pip=$(docker inspect $P --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}={{$v.IPAddress}} {{end}}')
echo "   proxy networks: $pip"
docker logs $P 2>&1 | grep -q "FAKE-demo" && bad "e1 secret in proxy log" || pass "e1 secret absent from proxy log"
echo "== restart persistence"
docker restart $P $R >/dev/null 2>&1; sleep 3
t  "f1 runner reaches proxy after restart"                   docker exec $R python3 -c "$PYCONN" $PROXY_IP 8899
tn "f2 runner still has no internet after restart"           docker exec $R python3 -c "$PYCONN" 1.1.1.1 53
exit $fail
