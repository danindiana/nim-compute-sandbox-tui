# MCP server (stdio, JSON-RPC 2.0, newline-delimited) exposing the compute sandbox as tools.
#
# IMPORTANT DESIGN RULE: this process never executes snippets itself. Every run is delegated
# to `sandbox_tui --run ...` -- by default through `docker exec -i <container>` so the code
# runs inside the sandbox container, not on the machine hosting the MCP server. `--local`
# (run the binary directly) exists for tests/CI only.
#
#   sandbox_mcp --container NAME [--exec-path /path/in/container/sandbox_tui] [--workdir DIR]
#               [--proxy HOST:PORT] [--max-timeout S]
#   sandbox_mcp --local --bin ./src/sandbox_tui [--dir RUNDIR] [--proxy HOST:PORT]   (tests only)
#
# Tools: run_code(lang, code, timeout_s?, net?, session?), list_gateways(), list_sessions().
# net is limited to off|proxy ("on" is refused). Credentials never pass through this server:
# gateways are referenced by alias and injected by egress_proxy.
import json, os, osproc, strutils, times

const
  ServerName = "sandbox-mcp"
  ServerVersion = "0.1.0"
  MaxCode = 100_000

type Cfg = object
  local: bool
  container, execPath, workdir, bin, dir, proxy: string
  maxTimeout: int

var cfg = Cfg(execPath: "/workspace/hermes-sessions/safetybox/real/sandbox_tui", maxTimeout: 60)

proc logErr(s: string) = stderr.writeLine "[sandbox_mcp] " & s

proc validName(s: string): bool =
  s.len in 1 .. 64 and s.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.', '/'}) and ".." notin s

proc validSession(s: string): bool =
  s.len in 1 .. 32 and s.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '_', '-'})

proc ok(id: JsonNode, res: JsonNode): JsonNode = %*{"jsonrpc": "2.0", "id": id, "result": res}
proc err(id: JsonNode, code: int, msg: string): JsonNode =
  %*{"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": msg}}

proc toolText(text: string, isError = false): JsonNode =
  %*{"content": [{"type": "text", "text": text}], "isError": isError}

proc tools(): JsonNode = %*{"tools": [
  {"name": "run_code",
   "description": "Run a code snippet in the isolated compute sandbox (python3, node or sqlite3). Output, exit status and timing are returned. Network is off unless net=proxy, which only reaches the egress proxy's allowlisted domains and credential-injecting gateway aliases (see list_gateways). Sessions keep files and the SQL database between calls.",
   "inputSchema": {"type": "object", "required": ["lang", "code"], "properties": {
     "lang": {"type": "string", "enum": ["python", "js", "sql"]},
     "code": {"type": "string", "maxLength": MaxCode},
     "timeout_s": {"type": "integer", "minimum": 1, "maximum": cfg.maxTimeout, "default": 10},
     "net": {"type": "string", "enum": ["off", "proxy"], "default": "off"},
     "session": {"type": "string", "pattern": "^[A-Za-z0-9_-]{1,32}$", "default": "default"}}}},
  {"name": "list_gateways",
   "description": "List the egress proxy's gateway aliases (names only; credentials are never exposed). Call a gateway from code run with net=proxy at $SANDBOX_GATEWAY/<alias>/<path>.",
   "inputSchema": {"type": "object", "properties": {}}},
  {"name": "list_sessions",
   "description": "List sandbox sessions and the bytes each uses.",
   "inputSchema": {"type": "object", "properties": {}}}]}

proc runnerCmd(args: seq[string], codeFile, outFile, errFile: string): string =
  ## shell line that runs sandbox_tui (in the container, or locally in --local mode)
  var parts: seq[string]
  if cfg.local:
    if cfg.dir.len > 0: parts.add "env SANDBOX_DIR=" & quoteShell(cfg.dir)
    if cfg.proxy.len > 0: parts.add "env SANDBOX_PROXY=" & quoteShell(cfg.proxy)
    parts.add quoteShell(cfg.bin)
  else:
    parts.add "docker exec -i"
    if cfg.workdir.len > 0: parts.add "-w " & quoteShell(cfg.workdir)
    if cfg.proxy.len > 0: parts.add "-e " & quoteShell("SANDBOX_PROXY=" & cfg.proxy)
    parts.add quoteShell(cfg.container)
    parts.add quoteShell(cfg.execPath)
  for a in args: parts.add quoteShell(a)
  let inRedir = if codeFile.len > 0: " < " & quoteShell(codeFile) else: " < /dev/null"
  result = parts.join(" ") & inRedir & " > " & quoteShell(outFile) & " 2> " & quoteShell(errFile)

proc delegate(args: seq[string], code: string, wallSec: int): tuple[ok: bool, stdoutText, err: string] =
  let tmp = getTempDir() / ("sbxmcp-" & $getCurrentProcessId() & "-" & $int(epochTime() * 1000))
  createDir(tmp)
  defer: removeDir(tmp)
  let codeFile = if code.len > 0: tmp / "code" else: ""
  if code.len > 0: writeFile(codeFile, code)
  let outFile = tmp / "out"
  let errFile = tmp / "err"
  let cmd = runnerCmd(args, codeFile, outFile, errFile)
  let p = startProcess("/bin/sh", args = ["-c", cmd], options = {poUsePath})
  discard p.waitForExit(wallSec * 1000)
  if p.running:
    p.kill()
    discard p.waitForExit()
    result.err = "runner exceeded its wall-clock budget and was killed"
    p.close()
    return
  let rc = p.peekExitCode()
  p.close()
  result.stdoutText = if fileExists(outFile): readFile(outFile) else: ""
  let e = if fileExists(errFile): readFile(errFile).strip() else: ""
  result.ok = rc == 0
  if not result.ok: result.err = "runner exited " & $rc & (if e.len > 0: ": " & e[0 ..< min(e.len, 300)] else: "")

proc callRunCode(a: JsonNode): JsonNode =
  let lang = a{"lang"}.getStr()
  let code = a{"code"}.getStr()
  let net = a{"net"}.getStr("off")
  let session = a{"session"}.getStr("default")
  let timeout = if a.hasKey("timeout_s"): a["timeout_s"].getInt(-1) else: 10
  if lang notin ["python", "js", "sql"]: return toolText("invalid lang (python | js | sql)", true)
  if code.len == 0: return toolText("code is required", true)
  if code.len > MaxCode: return toolText("code too large (max " & $MaxCode & " bytes)", true)
  if net notin ["off", "proxy"]: return toolText("net must be 'off' or 'proxy' ('on' is not available through MCP)", true)
  if not validSession(session): return toolText("invalid session name (letters, digits, _ or -, max 32)", true)
  if timeout < 1 or timeout > cfg.maxTimeout: return toolText("timeout_s must be 1.." & $cfg.maxTimeout, true)
  let r = delegate(@["--run", lang, "--timeout", $timeout, "--net", net, "--session", session], code, timeout + 20)
  if not r.ok: return toolText("sandbox runner failed: " & r.err, true)
  var j: JsonNode
  try: j = parseJson(r.stdoutText)
  except CatchableError: return toolText("sandbox runner returned invalid JSON", true)
  var head = "status: " & j{"status"}.getStr("?") & " (exit " & $j{"exit_code"}.getInt() & ", " &
             formatFloat(j{"secs"}.getFloat(), ffDecimal, 2) & "s, session " & j{"session"}.getStr() &
             ", net " & j{"net"}.getStr() & ")"
  if j{"timed_out"}.getBool(): head &= " - TIMED OUT after " & $timeout & "s"
  if j{"truncated"}.getBool(): head &= " - output truncated"
  let qw = j{"quota_warning"}.getStr()
  if qw.len > 0: head &= "\n" & qw
  toolText(head & "\n--- output ---\n" & j{"output"}.getStr())

proc callSimple(flag: string): JsonNode =
  let r = delegate(@[flag], "", 15)
  if not r.ok: return toolText("sandbox runner failed: " & r.err, true)
  toolText(r.stdoutText.strip())

proc handle(msg: JsonNode): JsonNode =
  ## returns nil for notifications (no response)
  let id = if msg.hasKey("id"): msg["id"] else: newJNull()
  let isNotification = not msg.hasKey("id")
  let meth = msg{"method"}.getStr()
  if meth.len == 0: return (if isNotification: nil else: err(id, -32600, "invalid request"))
  if meth.startsWith("notifications/"): return nil
  if isNotification: return nil
  case meth
  of "initialize":
    let pv = msg{"params", "protocolVersion"}.getStr("2024-11-05")
    return ok(id, %*{"protocolVersion": pv, "capabilities": {"tools": {}},
                     "serverInfo": {"name": ServerName, "version": ServerVersion},
                     "instructions": "Code execution tools backed by an isolated sandbox. No credentials ever pass through this server."})
  of "ping": return ok(id, newJObject())
  of "tools/list": return ok(id, tools())
  of "tools/call":
    let name = msg{"params", "name"}.getStr()
    let args = if msg{"params"}.hasKey("arguments"): msg["params"]["arguments"] else: newJObject()
    if args.kind != JObject: return err(id, -32602, "arguments must be an object")
    case name
    of "run_code": return ok(id, callRunCode(args))
    of "list_gateways": return ok(id, callSimple("--gateways"))
    of "list_sessions": return ok(id, callSimple("--sessions"))
    else: return err(id, -32602, "unknown tool: " & name)
  else: return err(id, -32601, "method not found: " & meth)

when isMainModule:
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    template val(): string =
      (if i < paramCount(): (inc i; paramStr(i)) else: quit("missing value for " & a, 2))
    case a
    of "--container": cfg.container = val()
    of "--exec-path": cfg.execPath = val()
    of "--workdir": cfg.workdir = val()
    of "--local": cfg.local = true
    of "--bin": cfg.bin = val()
    of "--dir": cfg.dir = val()
    of "--proxy": cfg.proxy = val()
    of "--max-timeout": cfg.maxTimeout = parseInt(val())
    of "-h", "--help":
      echo "usage: sandbox_mcp --container NAME [--exec-path P] [--workdir D] [--proxy H:P] [--max-timeout S]\n       sandbox_mcp --local --bin PATH [--dir D] (tests only)"
      quit 0
    else: quit("unknown option " & a, 2)
    inc i
  if cfg.local:
    if cfg.bin.len == 0 or not fileExists(cfg.bin): quit("--local needs --bin PATH to sandbox_tui", 2)
  else:
    if cfg.container.len == 0: quit("--container NAME is required (or --local for tests)", 2)
    if not validName(cfg.container) or not validName(cfg.execPath) or (cfg.workdir.len > 0 and not validName(cfg.workdir)):
      quit("container / exec-path / workdir contain unexpected characters", 2)
  if cfg.proxy.len > 0 and not cfg.proxy.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '.', ':', '-'}):
    quit("bad --proxy value", 2)
  if cfg.maxTimeout < 1 or cfg.maxTimeout > 600: quit("--max-timeout must be 1..600", 2)
  logErr("ready (" & (if cfg.local: "local runner, tests only" else: "docker exec -> " & cfg.container) & ")")
  while true:
    var line: string
    try: line = stdin.readLine()
    except EOFError: break
    if line.strip().len == 0: continue
    var msg: JsonNode
    try: msg = parseJson(line)
    except CatchableError:
      echo $err(newJNull(), -32700, "parse error")
      stdout.flushFile()
      continue
    if msg.kind != JObject:
      echo $err(newJNull(), -32600, "invalid request")
      stdout.flushFile()
      continue
    let resp = handle(msg)
    if resp != nil:
      echo $resp
      stdout.flushFile()
