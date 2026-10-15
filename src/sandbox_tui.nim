# Compute sandbox REPL: type code, end with a lone "." line; it runs in a subprocess
# (python3 / node / sqlite3) with a timeout, resource limits and a scrubbed environment.
# Output streams live; status, exit code and elapsed time follow.
#
#   sandbox_tui                         interactive REPL
#   sandbox_tui --run LANG [opts] < code   one-shot, prints one JSON object (used by MCP)
#   sandbox_tui --sessions | --gateways    JSON helpers for scripts
#     opts: --timeout S  --net off|proxy  --session NAME  --dir DIR
#
# Network (:net): off (default), proxy, on. off/proxy are a SOFT guard (monkeypatches);
# not a security boundary. proxy only reaches egress_proxy, which allowlists domains and
# injects credentials the sandboxed code never sees. See README.
import os, strutils, times, terminal, httpclient, json
from unicode import runeLen
import sandbox_core

const MaxHistory = 50

var
  sb = newSandbox(getEnv("SANDBOX_DIR", getCurrentDir() / ".runs"))
  history: seq[Run]
  lang = "python"

proc width(): int =
  result = terminalWidth()
  if result < 20 or result > 200: result = 80

proc rule() = echo "─".repeat(width())

proc banner() =
  let w = min(width(), 62)
  echo "┌" & "─".repeat(w - 2) & "┐"
  for l in ["Compute Sandbox - Nim TUI",
            "python | js | sql   timeout " & $sb.timeoutSec & "s   session " & sb.session,
            "net " & sb.netLabel()]:
    echo "│ " & l & " ".repeat(max(0, w - 4 - l.runeLen)) & " │"
  echo "└" & "─".repeat(w - 2) & "┘"
  echo "Enter code in the current language (" & lang & "). A line with just '.' runs it. ':help' for commands."

proc statusOf(r: Run): string =
  if r.timedOut: "TIMED OUT after " & $sb.timeoutSec & "s"
  elif r.exitCode == 0: "ok"
  else: "exit " & $r.exitCode

proc showStatus(r: Run) =
  echo statusOf(r) & "  (" & formatFloat(r.secs, ffDecimal, 2) & "s)"
  let w = sb.quotaWarning()
  if w.len > 0: echo w

proc show(r: Run) =
  rule()
  if r.output.len > 0:
    stdout.write r.output
    if not r.output.endsWith("\n"): echo ""
  rule()
  showStatus r

proc record(r: Run) =
  history.add r
  if history.len > MaxHistory: history.delete(0)

proc execute(lng, code: string) =
  ## run with live streaming, then record
  rule()
  var lastNl = true
  let r = sb.runCode(lng, code, proc (s: string) =
    stdout.write s
    stdout.flushFile()
    lastNl = s.endsWith("\n"))
  if not lastNl: echo ""
  if r.truncated: echo "[output truncated]"
  rule()
  showStatus r
  record r

proc help() =
  echo """Commands (only when no code is pending):
  :help          this text
  :history       list previous runs
  :show N        show output of run N
  :rerun N       run snippet N again
  :lang L        python | js | sql
  :net off|proxy|on  off = no network (soft guard); proxy = only via the egress
                 proxy (domain allowlist + credential injection); on = unrestricted
  :gateways      list the proxy's gateway aliases (names only, never secrets)
  :timeout S     wall-clock timeout in seconds (1..600)
  :limits        show resource limits;  :limits fsize|nofile|procs|cpu N  to change
                 (procs = RLIMIT_NPROC, per-uid host-wide, off by default; see README)
  :session NAME  switch session (own dir, HOME and sql db; created on first use)
  :ws            list sessions and sizes;  :wipe  clear the current session
  :clear         discard pending code (also works mid-entry)
  :quit          exit (also Ctrl+D / Ctrl+C)"""

proc parseIdx(s: string): int =
  try:
    result = parseInt(s.strip())
    if result < 1 or result > history.len: result = -1
  except ValueError:
    result = -1

proc command(line: string): bool =
  ## returns false to quit
  let parts = line.splitWhitespace()
  let arg = if parts.len > 1: parts[1] else: ""
  case parts[0]
  of ":help": help()
  of ":quit", ":q": return false
  of ":history":
    if history.len == 0: echo "(no runs yet)"
    for i, r in history:
      let first = r.code.splitLines()[0]
      echo $(i + 1) & ". " & r.lang & " [" & (if r.timedOut: "timeout" elif r.exitCode == 0: "ok" else: "exit " & $r.exitCode) & "] " & first
  of ":show":
    let i = parseIdx(arg)
    if i < 0: echo "usage: :show N (1.." & $history.len & ")" else: show(history[i - 1])
  of ":rerun":
    let i = parseIdx(arg)
    if i < 0: echo "usage: :rerun N (1.." & $history.len & ")"
    else: execute(history[i - 1].lang, history[i - 1].code)
  of ":timeout":
    try:
      let s = parseInt(arg)
      if s < 1 or s > 600: echo "timeout must be 1..600" else:
        sb.timeoutSec = s
        echo "timeout = " & $s & "s"
    except ValueError: echo "usage: :timeout SECONDS"
  of ":lang":
    if arg in ["python", "js", "sql"]:
      lang = arg
      echo "language = " & lang
    else: echo "usage: :lang python|js|sql (now " & lang & ")"
  of ":net":
    if arg in ["off", "proxy", "on"]: sb.netMode = arg
    else: echo "usage: :net off|proxy|on"
    echo "net = " & sb.netLabel()
  of ":gateways":
    try:
      let c = newHttpClient(timeout = 2000)
      defer: c.close()
      echo c.getContent("http://" & sb.proxyAddr & "/gw")
    except CatchableError as e:
      echo "proxy not reachable at " & sb.proxyAddr & " (" & e.msg & "); start egress_proxy first"
  of ":limits":
    if parts.len == 3:
      try:
        let n = parseInt(parts[2])
        if n < 1: raise newException(ValueError, "positive")
        case arg
        of "fsize": sb.limits.fsizeMB = n
        of "nofile": sb.limits.nofile = n
        of "procs": sb.limits.procMax = n
        of "cpu": sb.limits.cpuSlackSec = n
        else: echo "usage: :limits fsize|nofile|procs|cpu N"
      except ValueError: echo "limit must be a positive integer"
    echo "limits: file size " & $sb.limits.fsizeMB & " MB, open files " & $sb.limits.nofile &
         ", process cap " & (if sb.limits.procMax > 0: $sb.limits.procMax else: "off (container pids-limit applies)") & ", cpu = timeout + " & $sb.limits.cpuSlackSec &
         "s, address space 2 GB (python/sql; node: 512 MB V8 heap), session quota " & $sb.quotaMB & " MB (soft)"
  of ":session":
    if validSession(arg):
      sb.session = arg
      echo "session = " & arg & "  (" & sb.sessionDir & ")"
    else: echo "usage: :session NAME   (letters, digits, _ or -, max 32; now '" & sb.session & "')"
  of ":ws":
    let ss = sb.listSessions()
    if ss.len == 0: echo "(no sessions yet)"
    for (n, sz) in ss:
      echo (if n == sb.session: "* " else: "  ") & n & "  " & formatFloat(float(sz) / 1024.0, ffDecimal, 1) & " KB"
  of ":wipe":
    sb.wipeSession()
    echo "session '" & sb.session & "' cleared"
  of ":clear": discard
  else: echo "unknown command " & parts[0] & " (:help)"
  true

proc onSigint() {.noconv.} =
  echo "\nbye"
  quit(130)

# ---------------------------------------------------------------- one-shot CLI

proc oneShot() =
  ## sandbox_tui --run LANG [--timeout S] [--net off|proxy] [--session NAME] [--dir DIR]
  var lng = ""
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    template val(): string =
      (if i < paramCount(): (inc i; paramStr(i)) else: quit("missing value for " & a, 2))
    case a
    of "--run": lng = val()
    of "--timeout":
      sb.timeoutSec = parseInt(val())
    of "--net":
      let n = val()
      if n notin ["off", "proxy"]: quit("--net must be off or proxy", 2)
      sb.netMode = n
    of "--session":
      let n = val()
      if not validSession(n): quit("bad session name", 2)
      sb.session = n
    of "--dir": sb.baseDir = val()
    else: quit("unknown option " & a, 2)
    inc i
  if lng notin ["python", "js", "sql"]: quit("language must be python, js or sql", 2)
  if sb.timeoutSec < 1 or sb.timeoutSec > 600: quit("timeout must be 1..600", 2)
  let code = stdin.readAll()
  if code.len > 200_000: quit("code too large", 2)
  let r = sb.runCode(lng, code)
  let status = if r.timedOut: "timeout" elif r.exitCode == 0: "ok" else: "error"
  echo $(%*{"status": status, "exit_code": r.exitCode, "timed_out": r.timedOut,
            "secs": r.secs, "output": r.output, "truncated": r.truncated,
            "session": sb.session, "language": lng, "net": sb.netMode,
            "quota_warning": sb.quotaWarning()})

when isMainModule:
  if findExe("python3") == "":
    stderr.writeLine "python3 not found on PATH"
    quit(1)
  if paramCount() >= 1 and paramStr(1) == "--run":
    oneShot()
    quit(0)
  if paramCount() >= 1 and paramStr(1) == "--sessions":
    var arr = newJArray()
    for (n, sz) in sb.listSessions(): arr.add %*{"name": n, "bytes": sz}
    echo $(%*{"sessions": arr})
    quit(0)
  if paramCount() >= 1 and paramStr(1) == "--gateways":
    try:
      let c = newHttpClient(timeout = 2000)
      echo c.getContent("http://" & sb.proxyAddr & "/gw")
    except CatchableError as e:
      echo $(%*{"error": "proxy not reachable at " & sb.proxyAddr})
    quit(0)
  setControlCHook(onSigint)
  banner()
  var buf: seq[string]
  while true:
    stdout.write(if buf.len == 0: lang & "> " else: "... ")
    stdout.flushFile()
    var line: string
    try:
      line = stdin.readLine()
    except EOFError:
      echo ""
      break
    let t = line.strip()
    if t == ".":
      if buf.len == 0: continue
      let code = buf.join("\n") & "\n"
      buf.setLen(0)
      execute(lang, code)
    elif t == ":clear":
      buf.setLen(0)
      echo "(cleared)"
    elif buf.len == 0 and t.startsWith(":"):
      if not command(t): break
    else:
      buf.add line
