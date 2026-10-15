#!/usr/bin/env bash
# Writes a rules file containing only FAKE values, for verifying the deployment. Output: mode-600 file.
set -euo pipefail
OUT=${1:-$HOME/.config/sandbox-proxy/rules.demo.json}
mkdir -p "$(dirname "$OUT")"
umask 077
cat > "$OUT" <<JSON
{ "listen": "172.29.0.2:8899",
  "allow_domains": ["example.com"], "allow_ports": [443],
  "gateways": { "example": { "upstream": "https://example.com", "inject": { "X-Demo": "FAKE-demo-value-not-a-secret-1" } } } }
JSON
chmod 600 "$OUT"
echo "$OUT"
