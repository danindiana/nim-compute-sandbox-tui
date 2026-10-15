# Audit: Hermes's research & reproduction of Perplexity's compute sandbox
Date 2026-10-15 · Subject: output of the Hermes Agent project "safetybox" (a local-LLM agent run in a Docker sandbox)
Method: arXiv API title/abstract lookup (export.arxiv.org), `nim check` in the sandbox container, web search for Perplexity primary sources.

## Verdict
- The **literature is mostly real** (44/44 arXiv IDs resolve) but **~4 titles are attached to the wrong IDs** and **several quoted numbers are contradicted by the papers' own abstracts**.
- The **"Perplexity API spec" has no Perplexity source.** It is a design synthesized from generic agent-sandbox papers. It never cites Perplexity's own published material (see below), so it is not a reproduction.
- **Code:** only `real/sandbox_tui.nim` (written this session) runs Python. Everything else is stub, fake, or does not compile.

## 1. arXiv IDs (44 distinct IDs cited)
All 44 resolve. Wrong ID <-> title pairs:
| Cited as | ID | Actual title at that ID |
|---|---|---|
| CodeScope | 2406.00515 | A Survey on Large Language Models for Code Generation |
| Multi-SWE-bench | 2506.03524 | Seed-Coder: Let the Code Model Curate Data for Itself |
| xCodeEval | 2410.03981 | Survey on LLM code generation for low-resource/domain-specific languages (STATUS.md also lists this ID under a second title) |
| BigCodeBench | 2503.01245 | LLMs for Code Generation: A Comprehensive Survey (not BigCodeBench) |
Verified correct: 2402.01030 CodeAct, 2308.08155 AutoGen, 2307.13854 WebArena, 2404.07972 OSWorld, 2402.18679 Data Interpreter, 2305.06161 StarCoder, 2405.04324 Granite, 2507.10593 ToolRegistry, 2602.13559 OpAgent, 2601.16206, 2607.23933 SpecBox, 2609.38201 TomasuLLM, 2608.07925 ZhuLong, 2510.27287, 2604.00491, 2508.01279, 2504.16180, 2502.17348, 2606.10087, 2608.13854.
(Papers were never saved as PDFs; only summarized via web_extract.)

## 2. Claims vs abstracts
Core sandbox papers (PAPERS.md): **mostly accurate** — 2601.16206 (8x tokens), SpecBox (2.9x P99, 45.9% mem), TomasuLLM (1.31x/1.35x, 4,010 records, zero false accepts), ZhuLong (78.5% vs 23.6%, 22.1% fewer calls), EnterpriseBench (500 tasks, 41.8%) match. **Correction to this audit's first pass:** ZhuLong's "+43 pp over static RAG" is wrong (78.5% vs 23.6% is vs a pure LLM, a 54.9 pp gap; 41.2 pp is the drop when sandbox execution is removed). Full table for all 44 IDs: `research/PAPER_VERIFICATION.md`.

NON_PYTHON_PAPERS.md: **embellished or contradicted**
| Line | Claim | Abstract says |
|---|---|---|
| 12 | EAGER latency reduced 35-55% | up to **37.3%** end-to-end |
| 13 | "Sandbox: Open Interpreter" | not mentioned; EAGER is its own implementation |
| 20-21 | 2.5K+ tasks, 11 languages, Go 90%+ pass@1 | ChatGPT 3.5/4 asked for **3 scientific programs**; no pass@1, no 2.5K tasks |
| 28 | Rust "75%+ success" | Rust-SWE-bench: agents resolve **up to 21.2%**; RustForger best ~28% — 75% is false |
| 34-35 | 25+ languages, "2-5 s per compilation" | survey abstract gives neither |
| other | "RMarkdown + RStudio server" for ViseGPT | not evidenced by the cited paper |
Treat any number in NON_PYTHON_PAPERS.md not re-checked above as unverified.

## 3. Perplexity grounding (what is actually public)
Hermes cites none of these. Primary source: Perplexity's own post, "Sandbox API: isolated code execution for AI agents" (hub-prod.perplexity.ai/hub/blog/sandbox-api-isolated-code-execution-for-ai-agents). It states: Computer, Finance Agent and Deep Research run code in sandboxes; each session = its own **Kubernetes pod**; persistent filesystem via **FUSE**; Sandbox API supports **Python, JavaScript, SQL**; **no direct network by default**, egress via an outside proxy that matches domains and injects credentials (code never sees raw keys).
Secondary/unverified (third-party): "SPACE" runtime, Firecracker microVMs, ~125 ms boots, rolling snapshots (karozieminski.substack.com, techstrong.ai, createwith.com, pub.towardsai.net).
Compare API_SPEC.md: it describes `execute_bash/str_replace_editor/submit`, copy-on-write forking, intent-aware prewarming — ideas from SWE-agent/SpecBox/TomasuLLM, not from Perplexity. It does not mention k8s pods, FUSE, SQL, or the egress-proxy credential model.

## 4. Code triage (`nim check` in container)
| File | Result |
|---|---|
| core/main_skeleton.nim | compiles (warnings only; 25 lines, does nothing) |
| core/mcp_server.nim | FAIL: field named `method` (keyword) |
| core/python_sandbox.nim | FAIL: syntax error line 49; "execute" bodies are empty/stubs |
| core/sandbox.nim | FAIL: bad import path |
| core/tool_registry.nim | FAIL: undeclared `Json`, `dict` (Python-isms) |
| ui/console.nim | FAIL: imports non-existent `ratatui` |
| ui/main_tui.nim | FAIL: syntax error |
| app_perplexity_sandbox.nim (Hermes's newest, 12:01) | compiles, but **fake**: `execPython/execRust/execGo` just return the strings "Python ready"/"Rust compiler ready"; nothing is executed, yet header says "Python Execution Ready" |
| earlier app_* variants (app_tui, app_final, app_v1...) | no longer present — Hermes deleted/cleaned them since my first look |
| real/sandbox_tui.nim | works; runs python3 in a subprocess with timeout (tested) |
Stray file `core/python_sandbox.nim<newline><` still present.
Docs contradict each other: README/FINAL_SUMMARY/README_PERPLEXITY claim "complete"; ACTUAL_STATUS.md and NIM_TUI_STATUS.md admit Python execution was not implemented.

## 5. Recommendations (not done — need your OK)
1. Fix the 4 mismatched IDs/titles; strike or correct the numbers in section 2.
2. Retitle API_SPEC.md "Design inspired by agent-sandbox literature (not Perplexity's API)"; add a short section grounded in Perplexity's Sandbox API post (items in section 3).
3. Remove or label non-compiling core/ and ui/ files; delete the stray `<` file; stop describing app_perplexity_sandbox as executing code.
4. To get closer to the real thing in this stack: add JS/SQL execution to `real/sandbox_tui.nim`, a network-off default, and an egress-proxy stub — all things Perplexity actually documents.
5. Standing note: the agent's self-reported status claims need independent verification before publishing.

Sources: https://hub-prod.perplexity.ai/hub/blog/sandbox-api-isolated-code-execution-for-ai-agents · https://karozieminski.substack.com/p/perplexity-space-runtime-computer-agents · https://techstrong.ai/articles/perplexity-unveils-space-a-secure-sandbox-platform-for-ai-agents/ · https://www.createwith.com/tool/perplexity/updates/perplexity-unveils-space-sandbox-platform-for-persistent-agent-sessions

## Addendum 2026-10-15 (later): egress proxy built
Recommendation 4's egress-proxy item is now implemented as `src/egress_proxy.nim` with `:net proxy` in the TUI (see README, "The egress proxy").
Caveat repeated: in the tested single-container setup the proxy and sandboxed code share a uid, so the credential file is readable by the sandbox;
the implementation demonstrates the mechanism (gateway aliases, header injection, response redaction, CONNECT allowlist) rather than secret isolation.
No TLS interception is performed, so injection works for gateway aliases only.

## Addendum (later still): isolated deployment tested
`deploy/isolated/` splits the credential-holding proxy from the code runner using a docker `--internal` network (no route out for the runner,
rules file mounted only into the proxy container). `verify.sh` (18 checks) passes with **fake** credentials, including from raw Python that bypasses the
in-runner guard; an existing sandbox container was verified unaffected. This closes the single-container gap noted above; remaining caveats
(shared kernel, soft in-runner guard, host-side access to the rules file, daemon-restart/reboot/IPv6 untested) are listed in the README.
