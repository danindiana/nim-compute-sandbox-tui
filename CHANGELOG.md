# Changelog
## 2026-10-15
- Initial public release: sandbox_tui (python/js/sql, soft net guard, timeout), audit, corrected research notes, 8 diagrams, CI.
- Egress proxy (`src/egress_proxy.nim`): gateway aliases with credential injection + response redaction, CONNECT domain/port allowlist, mode-600 rules file, private-IP guard, request hardening. TUI: `:net off|proxy|on`, `:gateways`, snippets run under `env -i`. 28-check end-to-end test, diagrams 09-11, CI builds both binaries.
