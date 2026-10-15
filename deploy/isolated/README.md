# Isolated deployment (docker only)

Splits the credential-holding proxy from the code runner:

| Container | Networks | Holds |
|---|---|---|
| `sbx-proxy` | `sbx-iso` (internal) + an egress network | `egress_proxy`, the rules file (mounted read-only into this container only) |
| `sbx-runner` | `sbx-iso` only | `sandbox_tui`, session volume `sbx-runs`; no rules file, read-only rootfs |

`sbx-iso` is created with `docker network create --internal`, so the runner has no gateway, no internet and no route to the host.
The proxy listens only on its `sbx-iso` address, so containers on other networks cannot call its gateways.
No iptables, UFW, systemd or host-file changes are needed. `./up.sh`, `./verify.sh`, `./down.sh` (rollback).
