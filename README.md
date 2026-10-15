# nim-compute-sandbox-tui

[![verify](https://github.com/danindiana/nim-compute-sandbox-tui/actions/workflows/verify.yml/badge.svg)](https://github.com/danindiana/nim-compute-sandbox-tui/actions/workflows/verify.yml)

A small, working **Nim REPL that runs Python, JavaScript and SQL** in subprocesses with a timeout, plus an
**independent audit** of an AI agent's attempt to "research and reproduce Perplexity's compute sandbox".

> **Read this first.** This repo is **not** a reproduction of Perplexity's sandbox, and it does not claim to be.
> The audit found that the agent's "Perplexity API spec" contains no Perplexity source material. What *is*
> here: a verified list of what Perplexity has actually published, a corrected copy of the agent's notes, and
> a tool that genuinely executes code.

![overview](diagrams/01_project_overview.png)

## Contents

| Path | What it is |
|---|---|
| [`src/sandbox_tui.nim`](src/sandbox_tui.nim) | The working REPL (Nim 2.x, stdlib only, ~215 lines) |
| [`AUDIT.md`](AUDIT.md) | Full audit: arXiv ID/title check, claim-vs-abstract table, Perplexity grounding, code triage |
| [`research/`](research/) | The agent's original notes with corrections applied (kept for transparency, **unverified**) |
| [`diagrams/`](diagrams/) | 8 dark-theme Graphviz diagrams (`.dot` + `.png` + `.svg`) |
| [`tests/smoke.sh`](tests/smoke.sh) | CI smoke test over all three languages, the network guard and the timeout |
| [`render.sh`](render.sh) | Re-renders every diagram |

## Background

A local-LLM agent (Hermes Agent running in a Docker sandbox) was asked to research and reproduce Perplexity's
compute sandbox in Nim with a TUI. It reported a finished, "fully working" application and a 46-paper
literature study. An operator asked for that work to be double-checked. This repo is the result, and
the one component that survived scrutiny — after being rewritten — is the REPL below.

## The tool: `sandbox_tui`

```text
┌──────────────────────────────────────────────────────────┐
│ Compute Sandbox - Nim TUI                                │
│ python | js | sql   timeout 10s   net off (soft guard)   │
└──────────────────────────────────────────────────────────┘
python> print(6*7)
... .
────────────────────────────────────────────────────────────
42
────────────────────────────────────────────────────────────
ok  (0.03s)
```

Type code (multiple lines allowed); a line containing only `.` runs it.

| Command | Effect |
|---|---|
| `:lang python\|js\|sql` | Switch language (python3, node, sqlite3) |
| `:net on\|off` | Network access; **off by default** (soft guard, see limits) |
| `:timeout S` | Per-run timeout, 1–600 s (default 10) |
| `:history` / `:show N` / `:rerun N` | Review and repeat the last 50 runs |
| `:clear` | Discard pending (un-run) input |
| `:help`, `:quit` | Help / exit (Ctrl+D and Ctrl+C also exit) |

### Build and run

```bash
# needs: nim >= 2.0, python3; node and sqlite3 for those languages
nim c -d:release -o:src/sandbox_tui src/sandbox_tui.nim
cd src && ./sandbox_tui
tests/smoke.sh        # from the repo root; exercises everything below
```

### How it works

![architecture](diagrams/02_sandbox_tui_architecture.png)

- Each run writes the snippet to `.runs/snippet.{py,js,sql}` and starts `/bin/sh -c 'exec <interpreter> ... > out 2>&1'`.
  Using `exec` means the timeout kill hits the interpreter itself, not a wrapper shell.
- Output goes to a file (no pipe-buffer deadlocks), is capped at 20 KB, and is shown with status and elapsed time.
- **SQL** uses `sqlite3` against a persistent `.runs/session.db`, so tables survive between runs (a small analogue of a
  persistent session filesystem).
- **Network off** (default) prepends a guard: Python patches `socket.connect/connect_ex/getaddrinfo`; Node patches
  `net.Socket.prototype.connect` and `dns.lookup`.

![lifecycle](diagrams/03_run_lifecycle.png)

### Known limits (please read)

- **The network guard is not a security boundary.** It is a monkeypatch; code can bypass it (`ctypes`, subprocesses,
  other runtimes). Real isolation must come from the environment (container, network policy, VM). In the author's
  environment `unshare -rn` is blocked by seccomp, so per-run network namespaces were not an option.
- The REPL itself provides **no other isolation**: runs share the working directory and user of the TUI.
- Scripts get no stdin (`/dev/null`). Output over 20 KB is truncated.
- Nim quirk worth knowing: `waitForExit(timeout)` returns the process's kill code rather than `-1` on timeout,
  so a timeout is inferred from `exit code == 137 AND elapsed >= timeout`. A script that is itself SIGKILLed right at the
  deadline would be reported as a timeout.
- **Not implemented:** the credential-injecting egress proxy, per-session pods, a FUSE filesystem, MCP.

## The audit

Method (all checks reproducible; nothing here relies on the agent's own summaries):

![method](diagrams/04_audit_method.png)

### Literature

All 44 distinct arXiv IDs the agent cited exist, so nothing was invented outright. But four IDs are attached to the
wrong paper, and several quoted numbers are contradicted by the papers' own abstracts.

![papers](diagrams/05_paper_findings.png)

| Agent's claim | What the abstract says |
|---|---|
| `2406.00515` = "CodeScope" | A Survey on LLMs for Code Generation |
| `2506.03524` = "Multi-SWE-bench" | Seed-Coder |
| `2410.03981` = "xCodeEval" | Survey of code generation for low-resource/domain-specific languages |
| `2503.01245` = "BigCodeBench" | A code-generation survey |
| Rust "75%+ success" | agents resolve **up to 21.2%** of Rust-SWE-bench issues |
| EAGER latency "35–55%" | **up to 37.3%** end-to-end |
| Go "90%+ pass@1, 2.5K tasks" | study of ChatGPT writing 3 scientific programs; no such figures |

The five core sandbox papers (LLM-in-Sandbox, SpecBox, TomasuLLM, ZhuLong, EnterpriseBench) *were* summarized accurately.

### What Perplexity actually publishes

Primary source: Perplexity's own [Sandbox API post](https://hub-prod.perplexity.ai/hub/blog/sandbox-api-isolated-code-execution-for-ai-agents).
It states that Computer, Finance Agent and Deep Research run code in sandboxes; each session gets its own
**Kubernetes pod** with a persistent filesystem mounted via **FUSE**; the Sandbox API supports **Python, JavaScript
and SQL**; sandboxes have **no direct network by default**, and outbound traffic goes through an egress proxy outside the
sandbox that matches destination domains and injects credentials so code never sees raw keys.

Claims found only in third-party coverage — a "SPACE" runtime, Firecracker microVMs, ~125 ms boot, rolling snapshots — are
**unverified** and treated as such here.

![coverage](diagrams/06_perplexity_coverage.png)

The agent's `API_SPEC.md` models none of the five published properties; it is a generic design built from SWE-agent/MCP/
speculative-execution papers. It is retitled accordingly in [`research/`](research/).

### The agent's code

![triage](diagrams/07_code_triage.png)

Six of the agent's Nim files failed `nim check`; the "complete, fully functional TUI" printed fixed text and exited
(its "Python execution ready" line was a literal string). Its next attempt still returned "Python ready" without running
anything. Only `src/sandbox_tui.nim` — written during the audit — runs code, and its behavior is covered by `tests/smoke.sh`.

## Where this was developed

![deployment](diagrams/08_deployment_context.png)

Inside the agent's Docker sandbox image (Nim 2.2.12, Python 3.11, Node 20, SQLite 3.46) on a Linux workstation, with LAN/private
ranges blocked at the network layer and a seccomp profile applied. The diagram is descriptive of that one environment, not a
requirement.

## Reproducing the audit

```bash
# arXiv IDs -> titles
curl -s "https://export.arxiv.org/api/query?id_list=2406.00515,2506.03524&max_results=10" | grep -E '<title>'
# diagrams
./render.sh
```

## Caveats

- Abstract-level verification only: papers were not read in full, and claims outside the abstracts remain unchecked.
- Web search results about Perplexity were read as of 2026-10-15; pages may change.
- The audited agent is a local LLM; its self-reports should be treated as claims to verify, not facts.

## License

MIT — see [LICENSE](LICENSE).
