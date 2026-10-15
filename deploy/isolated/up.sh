#!/usr/bin/env bash
# Isolated deployment: the credential-holding proxy and the code runner live in different containers.
#   sbx-iso   : docker --internal network (no gateway, no internet, no host access)  [runner + proxy]
#   sbx-proxy : egress_proxy; on sbx-iso (listens only on its sbx-iso IP) AND on an egress network
#   sbx-runner: sandbox_tui runs here; ONLY on sbx-iso, rules file not mounted, rootfs read-only
# Docker commands only: no iptables, UFW, systemd or host-file changes. Undo with ./down.sh.
set -euo pipefail
NET=${NET:-sbx-iso}
SUBNET=${SUBNET:-172.29.0.0/24}
PROXY_IP=${PROXY_IP:-172.29.0.2}
EGRESS_NET=${EGRESS_NET:-hermes-sbx}        # existing network whose egress policy blocks LAN/metadata
IMAGE=${IMAGE:-hermes-sandbox:nim}
RULES=${RULES:-$HOME/.config/sandbox-proxy/rules.json}
BIN_DIR=${BIN_DIR:-$(cd "$(dirname "$0")/../../src" && pwd)}
UIDGID="$(id -u):$(id -g)"

die() { echo "error: $*" >&2; exit 1; }
[ -x "$BIN_DIR/egress_proxy" ] && [ -x "$BIN_DIR/sandbox_tui" ] || die "build egress_proxy and sandbox_tui into $BIN_DIR first"
[ -f "$RULES" ] || die "rules file not found: $RULES"
[ "$(stat -c %a "$RULES")" = "600" ] || die "$RULES must be mode 600"
docker network inspect "$EGRESS_NET" >/dev/null 2>&1 || die "egress network $EGRESS_NET not found"
docker network inspect "$NET" >/dev/null 2>&1 && die "network $NET already exists (run ./down.sh first)"
for c in sbx-proxy sbx-runner; do docker inspect "$c" >/dev/null 2>&1 && die "container $c already exists"; done
if docker network ls -q | xargs -r docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' | tr ' ' '\n' | grep -qx "$SUBNET"; then
  die "subnet $SUBNET already used by another docker network"
fi

echo "+ docker network create --internal --subnet $SUBNET $NET"
docker network create --internal --subnet "$SUBNET" "$NET" >/dev/null
docker volume create sbx-runs >/dev/null
# named volumes start root-owned; hand it to the runner uid (throwaway container, no network)
docker run --rm --network none --user 0:0 -v sbx-runs:/runs "$IMAGE" chown "$UIDGID" /runs

echo "+ start sbx-proxy (rules mounted read-only into THIS container only)"
docker run -d --name sbx-proxy --restart unless-stopped \
  --network "$NET" --ip "$PROXY_IP" --user "$UIDGID" \
  --read-only --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  --cap-drop ALL --security-opt no-new-privileges --memory 256m --pids-limit 128 \
  -v "$BIN_DIR/egress_proxy:/opt/sbx/egress_proxy:ro" \
  -v "$RULES:/etc/sandbox-proxy/rules.json:ro" \
  "$IMAGE" /opt/sbx/egress_proxy --listen "$PROXY_IP:8899" /etc/sandbox-proxy/rules.json >/dev/null
echo "+ docker network connect $EGRESS_NET sbx-proxy   (outbound path for the proxy only)"
docker network connect "$EGRESS_NET" sbx-proxy

echo "+ start sbx-runner (only on $NET)"
docker run -d --name sbx-runner --restart unless-stopped \
  --network "$NET" --user "$UIDGID" \
  --read-only --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --cap-drop ALL --security-opt no-new-privileges --memory 1g --pids-limit 256 \
  -e SANDBOX_PROXY="$PROXY_IP:8899" -e SANDBOX_DIR=/runs \
  -v sbx-runs:/runs \
  -v "$BIN_DIR/sandbox_tui:/opt/sbx/sandbox_tui:ro" \
  "$IMAGE" sleep infinity >/dev/null
sleep 1
docker logs sbx-proxy 2>&1 | tail -3
echo "up. runner: docker exec -i sbx-runner /opt/sbx/sandbox_tui --run python --net proxy < code.py"
echo "MCP:   sandbox_mcp --container sbx-runner --exec-path /opt/sbx/sandbox_tui --proxy $PROXY_IP:8899"
