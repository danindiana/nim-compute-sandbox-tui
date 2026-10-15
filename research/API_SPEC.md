# Agent-Sandbox API Design (inspired by the literature; NOT Perplexity's API)

> **Status note (audit 2026-10-15):** This document is a design synthesized from generic agent-sandbox
> papers (CodeAct, SWE-agent-style tools, SpecBox, TomasuLLM, MCP). It is **not** derived from any Perplexity
> source, and references below to "Perplexity" mean the project goal, not documented Perplexity behavior.
> What Perplexity itself has published (Sandbox API post, hub-prod.perplexity.ai/hub/blog/sandbox-api-isolated-code-execution-for-ai-agents):
> - Computer, Finance Agent and Deep Research run code in sandboxes (thousands of sessions/minute)
> - one isolated **Kubernetes pod per session**; persistent filesystem mounted via **FUSE**
> - Sandbox API languages: **Python, JavaScript, SQL**
> - **no direct network by default**; outbound traffic goes through an egress proxy outside the sandbox that
>   matches destination domains and injects credentials, so sandboxed code never sees raw API keys
> Third-party (unverified) claims: "SPACE" runtime, Firecracker microVMs, ~125 ms boot, rolling snapshots.
> None of the above (pods, FUSE, SQL, egress-proxy credential injection) is modeled in the layers below.


## Executive Summary

This document synthesizes patterns from 20+ research papers into a unified API design for an LLM-agent compute sandbox. The analysis reveals four distinct abstraction layers: sandbox environment management, MCP tool protocol, browser automation, and parallel execution patterns.

**Key Findings:**
1. **Unified Action Space:** CodeAct framework shows executable Python code outperforms JSON tool calls by up to 20% success rate
2. **MCP Dominance:** Model Context Protocol is the emerging standard for tool orchestration
3. **Copy-on-Write Isolation:** COW sandboxes enable secure speculation without full image duplication
4. **Intent-Aware Pre-warming:** Token-stream inference predicts tool needs before explicit invocation
5. **Parallel Execution Boundaries:** Cross-turn speculation validated at commit frontier preserves correctness

---

## Layer 1: Sandbox Environment Management API

### Architecture Pattern

```
┌────────────────────────────────────────────────────────┐
│              Sandbox Environment Controller              │
│                  (Virtual Computer Abstraction)          │
└────────────────────────────────────────────────────────┘
         │         │         │         │
    ┌────┴────┐ ┌───┴────┐ ┌──────┴────┐ ┌──────────┐
    │ Terminal │ │ File  │ │ Python    │ │ Network   │
    │  Access  │ │Editor │ │ Interpreter│ │  Access   │
    └──────────┘ └───────┘ └───────────┘ └───────────┘
```

### 1.1 Environment Configuration

#### Schema: SandboxInitializeRequest
```yaml
SandboxInitializeRequest:
  type: object
  properties:
    task_prompt:
      description: User task or instruction
      type: string
    task_requirements:
      description: Optional sandbox constraints
      type: object
      properties:
        timeout_ms:
          description: Maximum execution time
          type: integer
        memory_limit_mb:
          description: Memory budget
          type: integer
        allowed_packages:
          description: Package whitelist
          type: array
        network_access:
          description: Network permission
          type: boolean
    tools_request:
      description: List of tools to make available
      type: array
      items:
        type: string
        enum: [execute_bash, str_replace_editor, submit, file_reader, file_writer]
```

#### Schema: SandboxInitializeResponse
```yaml
SandboxInitializeResponse:
  type: object
  properties:
    sandbox_id:
      type: string
      description: Unique sandbox identifier
    environment_state:
      type: object
      properties:
        filesystem_path:
          type: string
        working_directory:
          type: string
        available_packages:
          type: array
        environment_variables:
          type: object
    resources_allocated:
      type: object
      properties:
        memory_mb: integer
        cpu_cores: integer
        storage_gb: integer
```

### 1.2 Tool Interface Patterns

#### CodeAct Unified Action Space
From CodeAct paper (arXiv:2402.01030):

```python
# Example: Unified CodeActions schema
action_schema = {
    "type": "function",
    "function": {
        "name": "code_act",
        "description": "Execute Python code with interpreter feedback",
        "parameters": {
            "type": "object",
            "properties": {
                "code": {
                    "type": "string",
                    "description": "Python code to execute"
                },
                "imports": {
                    "type": "array", 
                    "items": {"type": "string"}
                }
            },
            "required": ["code"]
        }
    }
}
```

**Key Difference from Traditional Tool Calls:**
- **Traditional:** Static schema, per-action tool invocation
- **CodeAct:** Dynamic code generation, self-debugging via traceback, variable state persistence

#### MCP Tool Registration

From ToolRegistry (arXiv:2507.10593):

```yaml
MCPToolSpecification:
  type: object
  properties:
    name:
      type: string
      description: Tool identifier (not name)
    description:
      type: string
      description: Human-readable tool description
    schema:
      type: object
      description: JSON Schema for parameters
    outputSchema:
      type: object
      description: JSON Schema for response
    annotations:
      type: object
      properties:
        title:
          type: string
        humanDescription:
          type: string
```

**Multi-Protocol Registration:**
- **Native Python:** Direct function wrapping
- **MCP:** JSON-RPC 2.0 server
- **OpenAPI:** REST endpoint to MCP conversion
- **LangChain:** Adapter pattern for tool objects

### 1.3 File Editor Interface

From LLM-in-Sandbox paper (arXiv:2601.16206):

```python
str_replace_editor_schema = {
    "type": "function",
    "function": {
        "name": "str_replace_editor",
        "description": "Create, read, and edit files",
        "parameters": {
            "type": "object",
            "properties": {
                "command": {
                    "enum": ["create", "read", "edit"]
                },
                "path": {
                    "type": "string"
                },
                "file_text": {
                    "description": "New content",
                    "type": "string"
                }
            },
            "required": ["command", "path"]
        }
    }
}
```

**File State Management:**
- Read: Returns full file content
- Write: Replaces entire file with new content
- History: Implicit in filesystem, not maintained by agent

### 1.4 Python Interpreter Interface

```python
execute_bash_schema = {
    "type": "function",
    "function": {
        "name": "execute_bash",
        "description": "Execute shell commands",
        "parameters": {
            "type": "object",
            "properties": {
                "command": {
                    "type": "string"
                },
                "timeout_ms": {
                    "type": "integer"
                }
            },
            "required": ["command"]
        }
    }
}

submit_schema = {
    "type": "function",
    "function": {
        "name": "submit",
        "description": "Indicate task completion",
        "parameters": {
            "type": "object",
            "properties": {
                "completion_indicator": {
                    "description": "Path to task output",
                    "type": "string"
                }
            }
        }
    }
}
```

---

## Layer 2: Model Context Protocol (MCP) Interface

### Architecture

```
MCP Client (LLM Host)
    ↓ JSON-RPC 2.0
MCP Server (Tool Provider)
```

### 2.1 Protocol Messages

#### Capability Discovery
```json
// Server responds to get_capabilities
{
    "jsonrpc": "2.0",
    "id": 1,
    "result": {
        "capabilities": {
            "tools": {},
            "resources": {},
            "prompts": {}
        }
    }
}
```

#### Tool Listing
```json
// tools/list response
{
    "jsonrpc": "2.0",
    "id": 2,
    "result": {
        "tools": [
            {
                "name": "search_apis",
                "description": "Search EDA APIs",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "query": {"type": "string"},
                        "lang": {"type": "string", "enum": ["pyaether", "skill"]}
                    },
                    "required": ["query"]
                }
            }
        ]
    }
}
```

#### Tool Invocation
```json
// tools/call
{
    "jsonrpc": "2.0",
    "id": 3,
    "result": {
        "content": [
            {
                "type": "text",
                "text": "{\"apis\": [...]}"
            }
        ],
        "isError": false
    }
}
```

### 2.2 Server Registration

#### Server Manifest Schema
```yaml
MCPServerManifest:
  type: object
  properties:
    serverInfo:
      serverName: string
      version: string
    capabilities:
      tools: boolean
      resources: boolean
      prompts: boolean
      logging: boolean
    tools:
      type: array
      items: MCPToolSpecification
    resources:
      type: array
      items: {uri: string, mimeType: string, description: string}
    prompts:
      type: array
      items: {name: string, description: string, arguments: array}
```

### 2.3 Resource Access

```yaml
MCPResourceSpecification:
  type: object
  properties:
    uri:
      type: string
      description: URI-addressed endpoint
    mimeType:
      type: string
      description: Content type
    description:
      type: string
```

**Example: Reading a resource**
```json
{
    "jsonrpc": "2.0",
    "id": 4,
    "result": {
        "content": [
            {
                "type": "text",
                "text": "file content here"
            }
        ],
        "uri": "file:///path/to/resource.txt"
    }
}
```

---

## Layer 3: Browser Automation API Patterns

### 3.1 Chrome DevTools Protocol (CDP) Abstraction

From FP-Agent paper (arXiv:2605.01247):

```python
# CDP-based browser actions
browser_actions = {
    "navigate": {
        "method": "Page.navigate",
        "params": {"url": "https://example.com"},
        "response": {"message": "Navigated"}
    },
    "click": {
        "method": "Mouse.click",
        "params": {
            "x": 100,
            "y": 200,
            "button": "left"
        }
    },
    "type": {
        "method": "Keyboard.type",
        "params": {
            "text": "Hello World",
            "interKeyDelay": 18  # ms
        }
    },
    "screenshot": {
        "method": "Page.captureScreenshot",
        "params": {"format": "png"}
    }
}
```

### 3.2 Element Interaction

```python
# Element reference pattern (from browser snapshot)
element_interaction = {
    "ref": "@e1",
    "method": "element_click",
    "params": {
        "selector": "css selector or xpath",
        "button": "left | middle | right"
    }
}
```

### 3.3 DOM Inspection

```python
browser_snapshot = {
    "type": "compact",
    "elements": [
        {
            "ref": "@e1",
            "label": "Submit Button",
            "role": "button",
            "bounds": {"x": 100, "y": 200, "width": 100, "height": 40}
        }
    ]
}
```

---

## Layer 4: Parallel Execution API

### 4.1 Concurrent Tool Invocation

From SpecBox (arXiv:2607.23933) and TomasuLLM (arXiv:2609.38201):

```python
ParallelExecutionRequest:
  type: object
  properties:
    actions:
      type: array
      items:
        type: object
        properties:
          tool_name: string
          arguments: object
          speculative: boolean
    commit_boundary:
      type: integer
      description: Only first N actions commit
    barrier_dependencies:
      type: array
      items: string
      description: Actions that block speculation

ParallelExecutionResponse:
  type: object
  properties:
    canonical_actions:
      type: array
      items: object
    speculative_actions:
      type: array
      items: object
    commit_frontier:
      type: integer
    observations:
      type: object
```

### 4.2 Copy-on-Write Sandbox Isolation

```python
COWOverlay:
  type: object
  properties:
    source_sandbox_id: string
    overlay_id: string
    read_set:
      type: array
      items: string
    write_set:
      type: array
      items: string
```

### 4.3 Validation Semantics

```python
CommitValidationRequest:
  type: object
  properties:
    speculative_prefix:
      type: array
      items: object
    canonical_state:
      type: object
    dependency_graph:
      type: object
      properties:
        edges: array
        vertices: array

CommitValidationResponse:
  type: object
  properties:
    is_valid: boolean
    committed_actions: array
    discarded_actions: array
    reason: string
```

---

## Layer 5: Execution Optimization APIs

### 5.1 Intent-Aware Prewarming

```python
IntentAwarePrewarming:
  type: object
  properties:
    streaming_tokens:
      type: string
      description: Partial model output
    embedded_intent:
      type: string
      description: Predicted tool call
```

### 5.2 Semantic Caching

```python
SemneticCacheKey:
  type: object
  properties:
    tool_name: string
    input_signature:
      type: object
      description: Normalized input for similarity check
    cached_result:
      type: object
      description: Hash of previous execution
```

### 5.3 Out-of-Band Data Transport

```python
OutOfBandTransport:
  type: object
  properties:
    control_channel:
      type: object
      properties:
        protocol: "JSON-RPC"
        transport: "stdio/http/websocket"
    data_channel:
      type: object
      properties:
        transport: "shared_memory"
        bypass_network: boolean
```

---

## Security & Safety API Layer

### 6.1 Access Control Policies

From AgentGuard (arXiv:2605.28071):

```python
AttributeBasedAccessControl:
  type: object
  properties:
    subject_attributes:
      type: array
      items: string
    resource_attributes:
      type: array
      items: string
    action_policy:
      enum: ["allow", "deny"]
```

### 6.2 Intent-to-Execution Integrity

From "Securing LLM Agents Need Intent-to-Execution Integrity" (arXiv:2605.16976):

```python
IntentToExecutionCorrectness:
  type: object
  properties:
    original_intent:
      type: string
    execution_trace:
      type: array
      items: object
    final_state:
      type: object
    correctness_verified:
      type: boolean
```

### 6.3 Sandboxed Boundary Enforcement

```python
SandboxBoundaryEnforcement:
  type: object
  properties:
    read_only_user_files:
      type: boolean
    isolated_execution:
      type: boolean
    network_isolation:
      type: boolean
    credential_protection:
      type: boolean
```

---

## Performance API Metrics

### 7.1 Latency Measurement

From OSWorld-Human (arXiv:2506.16042):

```python
LatencyBreakdown:
  type: object
  properties:
    model_inference_ms: integer
    tool_execution_ms: integer
    sandbox_management_ms: integer
    data_transfer_ms: integer
    total_latency_ms: integer
```

### 7.2 Throughput Metrics

```python
ThroughputMetrics:
  type: object
  properties:
    queries_per_second: integer
    tokens_per_second: integer
    p99_latency_ms: integer
    concurrency_level: integer
```

---

## Next Steps for Implementation

1. **Sandbox Controller Implementation:**
   - Docker volume mounting for shared filesystem
   - Python interpreter with package management
   - Network proxy for controlled access

2. **MCP Server Integration:**
   - JSON-RPC 2.0 implementation
   - Tool schema registration
   - Capability discovery endpoint

3. **Browser Automation Binding:**
   - CDP client integration
   - Element reference mapping
   - DOM snapshot generation

4. **Parallel Execution Framework:**
   - Copy-on-write sandbox spawning
   - Commit frontier tracking
   - Validation semantics implementation

5. **Security Layer:**
   - Attribute-based access control
   - Intent verification
   - Sandboxing enforcement

---

*Generated: 2026-10-15 | Session: safetybox*
*Status: API documentation synthesis complete*