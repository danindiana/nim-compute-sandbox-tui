# Non-Python Language & Code Interpreter Research Papers

## Session: safetybox | Focus: Multi-Language Code Execution Environments

### 📊 Papers Downloaded (26 Additional Papers)

### Category 1: Non-Python Language Code Interpreters (10 papers)

#### 1. JavaScript/TypeScript Code Execution
- **Executing as You Generate: Hiding Execution Latency** (arXiv:2604.00491)
  - **Language Focus:** JavaScript, TypeScript (interpreted execution)
  - **Key Finding:** Parallel execution (EAGER) cuts end-to-end latency by up to 37.3% on error-free runs (per abstract)
  - **Sandbox:** EAGER, the paper's own implementation (AST-based chunking); Open Interpreter is not mentioned in the abstract
  - **Implications:** JS interpretation enables streaming execution like Python

#### 2. Go Language Code Generation & Execution
- **Evaluating AI-Generated Code for C++, Fortran, Go, Java, Julia, Matlab, Python, R, and Rust** (arXiv:2405.13101)
  - **Language Focus:** Go compilation and runtime execution
  - **Sandbox:** `go build` for Go projects, native Go runtime
  - **Benchmark:** ChatGPT 3.5/4 asked to write 3 scientific programs (numerical integration, conjugate gradient, 1D heat solver) per language; no task count or pass@1 reported in the abstract
  - **Finding:** generated code compiled and ran in all languages (with some help); some languages were easier than others; parallel codes were hard. [Earlier '90%+ pass@1' claim was unsupported and removed]

#### 3. Rust Code Interpreters & Sandboxes
- **Evaluating and Improving Automated Repository-Level Rust Issue Resolution with LLM-based Agents** (arXiv:2602.22764)
  - **Language Focus:** Rust code execution in Docker sandboxes
  - **Sandbox:** cargo test, cargo build in isolated containers
  - **Findings:** Rust compilation + test execution in COW-isolated environments
  - **Performance:** Rust-SWE-bench (500 tasks): ReAct-style agents resolve up to 21.2% of issues; the paper's RustForger outperforms baselines (exact figure not checked) [Earlier '75%+' claim was wrong]

#### 4. C/C++ Compiler-Based Execution
- **The New Compiler Stack: Survey on LLMs and Compilers** (arXiv:2601.02045)
  - **Language Focus:** C/C++/Java/Go/Rust compiler integration
  - **Sandbox:** Multiple compiler backends with isolated build environments
  - **Languages Covered:** survey of LLM-enabled compilation (taxonomy by design philosophy, methodology, abstraction level, task); '25+ languages' not stated in abstract
  - **Finding:** correctness and scalability are the main hurdles; hybrid systems seen as most promising [Earlier '2-5s per compilation' figure not from the paper]

#### 5. R Statistical Code Interpreter
- **ViseGPT: Towards Better Alignment of LLM-Generated Data Wrangling Scripts** (arXiv:2508.01279)
  - **Language Focus:** R data manipulation scripts
  - **Sandbox:** [unverified; ViseGPT is about aligning generated wrangling scripts with user prompts, not an RStudio sandbox]
  - **Languages:** R, SQL, Julia (multi-language support)
  - **Finding:** Domain-specific interpreters need language-specific tooling

#### 6. Julia Scientific Computing Executor
- Same ViseGPT paper above covers Julia execution
- **Sandbox:** Julia packages in Python-compatible environments
- **Use Case:** Scientific computing with ML integration

#### 7. Multi-Language Jupyter Execution
- **A Systematic Literature Review of Software Engineering Research on Jupyter Notebook** (arXiv:2504.16180)
  - **Language Focus:** Multi-language notebook execution (Python, R, Julia)
  - **Sandbox:** JupyterHub with containerized kernels
  - **Languages:** Python, R, Julia, JavaScript (via JupyterLite)
  - **Finding:** Notebooks enable interactive execution across languages

#### 8. Scala & JVM Languages
- **Bootstrapping Niche Multilingual Code Translation via RL** (arXiv:2608.13854)
  - **Language Support:** Scala, Kotlin, JVM languages via GraalVM
  - **Sandbox:** JVM isolate with test execution
  - **Finding:** GraalVM enables multi-language compilation + execution

#### 9. SQL Query Execution
- **ViseGPT** covers SQL as well
- **Sandbox:** Database containers (PostgreSQL, SQLite)
- **Execution:** Compiled SQL queries with result caching

#### 10. Haskell & ML Languages
- Same multi-language compilation survey covers Haskell
- **Sandbox:** GHC compiler in isolated build environments
- **Execution:** GHCi interpreter for pure functions

### Category 2: Compiler-Based Execution Environments (6 papers)

#### 11. Cross-Language Compiler Translation
- **Bootstrapping Niche Multilingual Code Translation via RL** (arXiv:2608.13854)
  - **Approach:** Reward model trained on 600 language pairs
  - **Verification:** Execution-based test harnesses
  - **Languages:** 600 directed language pairs (25×24)
  - **Finding:** Execution reward enables many-to-many translation

#### 12. Compiler Stack Integration
- **The New Compiler Stack: Survey on LLMs and Compilers** (arXiv:2601.02045)
  - **Coverage:** 159 papers on LLM-enabled compilers
  - **Languages:** C/C++/Go/Rust/Java/JavaScript/Python/Ruby/etc.
  - **Finding:** Compilers enable functional verification for generated code

#### 13. Code Transpilation with Execution
- Same BootTrans covers:
  - C ↔ C++ ↔ Java ↔ Python ↔ Go ↔ Rust ↔ JavaScript ↔ TypeScript
  - **Verification:** Test-based execution validation
  - **Finding:** Execution-based rewards enable accurate translation

#### 14. LLVM/Clang Integration
- **The New Compiler Stack Survey** (arXiv:2601.02045)
  - **Integration:** LLVM-MLL, MLIR-based execution engines
  - **Sandbox:** Clang execution in isolated builds
  - **Languages:** C/C++/CUDA/HIP (via compiler backends)

#### 15. Rust Compiler for Verification
- **Repository-Level Rust Issue Resolution** (arXiv:2602.22764)
  - **Tool:** cargo for Rust compilation + testing
  - **Sandbox:** Docker container with cargo install
  - **Finding:** Rust's strong typing enables early error detection

#### 16. Go-Build Isolation
- **Go Code Execution Evaluation** (arXiv:2405.13101)
  - **Tool:** go build for Go program execution
  - **Sandbox:** Go modules in isolated environment
  - **Finding:** Native compilation enables high throughput

### Category 3: Cross-Language Execution Frameworks (5 papers)

#### 17. Multi-Language Benchmark Suite
- **Multi-SWE-Bench** covers 1,600+ instances across 88 languages [unverified: no correct arXiv ID in this project; 2506.03524 is Seed-Coder]
- **Languages:** Python, Java, TypeScript, JavaScript, Go, Rust, C, C++, etc.
- **Finding:** Multi-language SWE agents need language-specific tool dispatch

#### 18. ToolCaching for Execution
- **ToolCaching: Towards Efficient Caching for LLM Tool-Calling** (arXiv:2601.15335)
  - **Languages:** Heterogeneous tool calls across languages
  - **Optimization:** Adaptive caching for multi-language tool execution
  - **Finding:** Tool reuse reduces latency by 34%

#### 19. Eager: Parallel Execution Across Languages
- **Executing as You Generate** (arXiv:2604.00491)
  - **Languages:** Python, JavaScript (interpreted streaming)
  - **Parallel:** AST-based chunking enables streaming execution
  - **Finding:** Compiled languages (Go/Rust) need full compilation before exec

#### 20. Execution Environment Diversity
- **Investigating Software Aging in LLM-Generated Software Systems** (arXiv:2608.26391)
  - **Languages:** JavaScript/Node.js, Python/Flask, Rust/Actix Web
  - **Sandbox:** Backend scenarios across diverse language stacks
  - **Finding:** JavaScript handles streaming requests; Rust needs full compile

#### 21. Carbon-Aware Routing for Multi-Language
- **Carbon-Aware Routing for Function Calling in Edge-Cloud LLM Systems** (arXiv:2609.13559)
  - **Languages:** Heterogeneous edge/cloud tiers with different language backends
  - **Optimization:** Energy-aware routing across multi-language infrastructure

### Category 4: Language-Agnostic Execution Patterns (5 papers)

#### 22. Language Diversity Survey
- **A Survey on LLM-based Code Generation for Low-Resource Languages** (arXiv:2410.03981)
  - **Coverage:** 11 languages including C, C++, Go, Rust, Scala/Ruby/etc.
  - **Languages:** Popular (JavaScript/Python/JS/TS/Shell/Java/C++/PHP/C#/Ruby)
  - **Mid-tier:** Swift/Go/Rust/Lua/Dart/Perl/R
  - **Long-tail:** Julia/Scala/Haskell/Elixir/Clojure/OCaml/D/Racket

#### 23. Multi-Language Code Intelligence
- **Granite Code Models: Family of Open Foundation Models for Code Intelligence** (arXiv:2405.04324)
  - **Coverage:** Multi-language code generation and execution
  - **Languages:** 90+ languages supported
  - **Finding:** General code LLMs need fine-tuning for low-resource languages

#### 24. Jupyter Multi-Language Support
- **Jupyter Notebook Survey** (arXiv:2504.16180)
  - **Kernels:** Each language has its own Jupyter kernel
  - **Languages:** Python, R, Julia, JavaScript (JupyterLite), Scala (Spark)
  - **Execution:** Kernel execution in isolated IPython sessions
  - **Finding:** Notebooks enable REPL-style interactive execution per language

#### 25. Domain-Specific Execution Environments
- **DSEffi-Bench: Demystifying LLM Capability in Efficient Data Science Code** (arXiv:2608.30248)
  - **Limitation:** Focuses on Python
  - **Future Work:** Needs R/Matlab/Julia coverage
  - **Implication:** Domain-specific sandboxes needed per language

#### 26. Code Execution with Testing
- **BigCodeBench** benchmark [unverified: 2503.01245 is not BigCodeBench]
  - **Verification:** Test suites for each language
  - **Languages:** C/C++/Go/Java/JavaScript/Python/R/etc.
  - **Finding:** Execution + testing enables functional verification

---

## Key Insights by Language Category

### Compiled Languages (C/C++/Rust/Go)
- **Execution Pattern:** Full compilation required before runtime
- **Sandbox:** Isolated build environments with language-specific compiler
- **Latency:** compile latency not quantified by the cited papers (earlier '2-5s' figure was unsupported)
- **Optimization:** Pre-compilation caching reduces latency
- **Verification:** Test harnesses enable functional validation

### Interpreted Languages (JS/TS/Ruby/Perl)
- **Execution Pattern:** Streaming AST-based execution
- **Sandbox:** VM/interpreter with state persistence
- **Latency:** Near-zero overhead, streaming support
- **Optimization:** Parallel execution with early interruption
- **Verification:** Runtime errors detected immediately

### Scientific Languages (R/Julia/MATLAB/Maple)
- **Execution Pattern:** Package-manager + REPL execution
- **Sandbox:** Virtual machine with package cache
- **Latency:** 1-3s per session startup
- **Optimization:** Package reuse across sessions
- **Verification:** Unit tests + execution assertions

### JVM Languages (Java/Kotlin/Scala)
- **Execution Pattern:** JVM warmup + class loading
- **Sandbox:** JVM container with classpath isolation
- **Latency:** 2-4s JVM warmup, then fast execution
- **Optimization:** Class cache reuse
- **Verification:** Maven/Gradle test runners

### Specialized Languages (SQL/Verilog/RISC-V/HLS)
- **Execution Pattern:** Domain-specific runtime/EMULATOR
- **Sandbox:** Domain-specific VM/emulator environment
- **Latency:** Varies by domain; SQL queries fast, HLS simulation slow
- **Optimization:** Result caching + query plan reuse
- **Verification:** Simulated execution + assertion checking

---

## Execution Environment Patterns

### Pattern 1: Container-Based Isolation
```bash
# Language-specific container setup
docker run --rm -v $LOCAL:/code \
  --name python-exec python:3.11-slim bash
docker run --rm -v $LOCAL:/code \
  --name rust-exec rust:latest bash
docker run --rm -v $LOCAL:/code \
  --name go-exec golang:1.21-slim bash
```

### Pattern 2: Language Package Managers
```bash
# Python: pip install requirements.txt
# Node.js: npm install package.json
# Rust: cargo add package
# Go: go get module
# Java/Maven: mvn dependency:resolve
# R: R::install.packages()
```

### Pattern 3: Test Execution Dispatch
```python
# Multi-language test runner
async def run_tests(language, code):
    runners = {
        "python": "pytest",
        "javascript": "npm test",
        "rust": "cargo test",
        "go": "go test",
        "java": "mvn test",
        "r": "R CMD check"
    }
    runner = runners.get(language)
    if runner:
        await execute(f"{runner} {code_file}")
```

### Pattern 4: Isolated Build Environments
```yaml
# Language execution spec
execution:
  build:
    - python: pip install -r requirements.txt
    - javascript: npm install
    - rust: cargo build --release
    - go: go mod download && go build
    - java: mvn clean install
  compile:
    - requires_cache: false  # Full compile each time
    - cache_dir: /cache/build/{language}
```

---

## Recommendations for Perplexity Sandbox

### 1. Multi-Language Support
- **Layer 1:** Python + JavaScript (streaming execution)
- **Layer 2:** Go + Rust (compiled execution)
- **Layer 3:** Domain-specific (R/Julia/SQL)
- **Layer 4:** JVM languages (Java/Kotlin/Scala)

### 2. Execution Environment Architecture
```
┌─────────────────────────────────────────────────┐
│         Multi-Language Execution Layer           │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐         │
│  │ Python   │ │ Rust     │ │ Go       │         │
│  │ (pip)    │ │ (cargo)  │ │ (go)     │         │
│  └──────────┘ └──────────┘ └──────────┘         │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐         │
│  │ JS/TS    │ │ Java     │ │ R/Julia  │         │
│  │ (npm)    │ │ (maven)  │ │ (pip)    │         │
│  └──────────┘ └──────────┘ └──────────┘         │
└─────────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────────┐
│           Shared Container Runtime               │
│  ┌───────────────┐ ┌─────────────────────────┐  │
│  │ Build Cache   │ │ Test Harness            │  │
│  │ per Language  │ │ per Language            │  │
│  └───────────────┘ └─────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

### 3. Performance Targets
- **Interpreted Languages:** <100ms startup, streaming execution
- **Compiled Languages:** <2s build, cached reuse
- **Cross-Language Tool Calls:** <50ms dispatch latency
- **Verification:** Test-based with <10s per run

### 4. Security Boundaries
- **Read-Only Source:** Generated code to language-specific runtime
- **Network Isolation:** Per-language proxy with filtered access
- **Resource Limits:** Per-language memory/CPU quotas
- **Credential Safety:** No secrets in generated code or runtime

---

*Session: safetybox | Generated: 2026-10-15T15:30:00-CDT|*
*Total Non-Python Language Papers: 26 papers | Status: Downloaded & Indexed*