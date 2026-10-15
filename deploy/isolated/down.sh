#!/usr/bin/env bash
# Roll back everything up.sh created. Pass --volumes to also delete the runner's session volume.
set -uo pipefail
docker rm -f sbx-runner sbx-proxy 2>/dev/null
docker network rm sbx-iso 2>/dev/null
[ "${1:-}" = "--volumes" ] && docker volume rm sbx-runs 2>/dev/null
echo "removed sbx-runner, sbx-proxy, network sbx-iso${1:+ (and volume sbx-runs)}"
