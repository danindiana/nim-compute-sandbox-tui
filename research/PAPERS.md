# Downloaded Research Papers for Perplexity AI Compute Sandbox Analysis

## Collected Papers

### Core Research Papers on LLM Sandboxing

1. **[Computer Environments Elicit General Agentic Intelligence in LLMs](https://arxiv.org/abs/2601.16206)**
   - **arXiv ID:** 2601.16206v2
   - **Status:** Downloaded via web_extract
   - **Key Topics:** LLM-in-Sandbox, code sandbox environments, general agentic intelligence
   - **Key Findings:**
     - up to 8x reduction in token consumption (abstract). [The '100K → 13K tokens' example is not in the abstract; 100/13 ≈ 7.7x is consistent but unverified]
     - LLMs spontaneously leverage sandbox for non-code tasks
     - Three meta-capabilities: external resource access, file management, code execution
     - Minimal toolset with exploratory design principle
   - **Relevance:** Directly relevant to understanding sandboxed execution patterns

2. **[SpecBox: Speculative Sandbox Scheduling for Efficient LLM Agent Serving](https://arxiv.org/abs/2607.23933)**
   - **arXiv ID:** 2607.23933v1
   - **Status:** Downloaded via web_extract
   - **Key Topics:** Sandbox prewarming, speculative scheduling, latency optimization
   - **Key Findings:**
     - Cuts P99 latency by 2.9x compared to on-demand sandbox
     - 45.9% reduction in peak memory consumption
     - Intent-Aware Prewarming, Stochastic Prefetching, Reuse-Aware Data Transmission
     - Semantic result caching to prune redundant executions
   - **Relevance:** Shows performance optimization patterns for sandbox execution

3. **[TomasuLLM: Out-of-Order Speculative Execution for LLM Agents](https://arxiv.org/abs/2609.38201)**
   - **arXiv ID:** 2609.38201v2
   - **Status:** Downloaded via web_extract
   - **Key Topics:** Out-of-order execution, speculative execution, copy-on-write sandboxes
   - **Key Findings:**
     - 1.31x speedup on SWE-bench Verified, 1.35x on Terminal-Bench 2.0
     - Drafts future actions, runs in isolated copy-on-write sandboxes
     - Traces dependencies and effects, commits results in trajectory order
     - Zero false accepts across 4,010 audited records
   - **Relevance:** Cross-turn speculative execution patterns

4. **[Execution-Grounded LLM Agent for EDA Scripting with Offline API Self-Exploration](https://arxiv.org/abs/2608.07925)**
   - **arXiv ID:** 2608.07925v1
   - **Status:** Downloaded via web_extract
   - **Key Topics:** MCP tools, sandbox execution, API self-exploration
   - **Key Findings:**
     - 78.5% Pass@1 vs 23.6% for a pure-LLM baseline (a 54.9 pp gap, abstract). [The earlier '+43 pp over static RAG' was wrong: the abstract's 41.2 pp figure is the drop when sandbox execution is removed, and the baseline is a pure LLM, not static RAG]
     - Three MCP tools: search_apis, get_api_details, run_code
     - Offline API self-exploration for undocumented APIs
     - 22.1% reduction in tool calls via self-exploration
   - **Relevance:** MCP tool usage patterns for sandbox execution

5. **[Can LLMs Help You at Work? A Sandbox for Evaluating LLM Agents in Enterprise Environments](https://arxiv.org/abs/2510.27287)**
   - **arXiv ID:** 2510.27287v1
   - **Status:** Downloaded via web_extract
   - **Key Topics:** Enterprise benchmarks, sandbox evaluation, access control
   - **Key Findings:**
     - 500 diverse tasks across software engineering, HR, finance, and administrative domains (abstract says 'administrative', not 'IT')
     - First comprehensive enterprise benchmark simulation
     - Persona-based tasks with access control hierarchies
     - Even SOTA models achieve only 41.8% task completion
   - **Relevance:** Enterprise sandbox security and access control patterns

### Additional Key Papers (Not yet downloaded)

6. **LLM-in-Sandbox Elicits General Agentic Intelligence - Full paper needed**
   - The PDF was truncated during extraction
   - Need to download full PDF for complete analysis
   - URL: https://arxiv.org/pdf/2601.16206.pdf

7. **SpecBox Full Paper**
   - HTML version downloaded, need PDF
   - URL: https://arxiv.org/pdf/2607.23933.pdf

8. **TomasuLLM Full Paper**
   - HTML version downloaded, need PDF
   - URL: https://arxiv.org/pdf/2609.38201.pdf

## Analysis Status

### Completed Downloads
- [x] Computer Environments Elicit General Agentic Intelligence (arXiv:2601.16206)
- [x] SpecBox: Speculative Sandbox Scheduling (arXiv:2607.23933)
- [x] TomasuLLM: Out-of-Order Speculative Execution (arXiv:2609.38201)
- [x] ZhuLong: Execution-Grounded LLM Agent (arXiv:2608.07925)
- [x] EnterpriseBench Sandbox Evaluation (arXiv:2510.27287)

### Downloads in Progress
- [ ] Full PDFs for remaining papers
- [ ] Paper summaries and key insights extraction
- [ ] Implementation pattern documentation

### Key Themes Identified
- **Sandbox Initialization & Pre-warming:** Lazy instantiation vs. pre-provisioning
- **Copy-on-Write Isolation:** Secure execution boundaries for tool calls
- **Speculative Execution:** Drafting future actions, out-of-order processing
- **MCP Protocol:** Standardized interface for sandbox tooling
- **Semantic Caching:** Reuse of equivalent tool results
- **Intent-Aware Prefetching:** Predictive scheduling based on token streams
- **Out-of-Order Execution:** CPU-inspired techniques for tool orchestration
- **Security Boundaries:** Read-only user files, isolated execution environments

## Next Steps

1. **Download Full PDFs:**
   - Complete truncated PDF extractions
   - Store originals in `/workspace/hermes-sessions/arxiv/PAPERS/`

2. **Summarize Each Paper:**
   - Extract key architectural patterns
   - Document tool schemas and interfaces
   - Identify API specifications

3. **Create Implementation Guide:**
   - Synthesize patterns from all papers
   - Draft equivalent tool interface
   - Design parallel execution strategy

4. **Security Analysis:**
   - Review sandbox isolation mechanisms
   - Document credential protection patterns
   - Analyze access control implementations

---
*Generated: 2026-10-15 | Session: arxiv*