# Compute sandbox REPL: type code, end with a lone "." line, it runs in a
# subprocess with a timeout; output, exit code and elapsed time are shown.
# Languages: python (default), js (node), sql (sqlite3, persistent session.db).
# Network is OFF by default via a SOFT guard (python socket / node net patches);
# it is a convenience check, NOT a security boundary.
import os, osproc, strutils, times, terminal
from unicode import runeLen

const
  MaxHistory = 50
  MaxOutput = 20_000          # bytes of output shown per run

type Run = object
  lang: string
  code: string
  output: string
  exitCode: int
  timedOut: bool
  secs: float

const
  PyGuard = """import socket as _s
def _deny(*a, **k):
    raise OSError("network disabled in sandbox (use :net on)")
_s.socket.connect = _deny
_s.socket.connect_ex = _deny
_s.getaddrinfo = _deny
import runpy, sys
sys.argv = [sys.argv[1]]
runpy.run_path(sys.argv[0], run_name="__main__")
"""
  JsGuard = """const net = require('net'), dns = require('dns');
const deny = () => { throw new Error('network disabled in sandbox (use :net on)'); };
net.Socket.prototype.connect = deny;
dns.lookup = deny;
"""

var
  history: seq[Run]
  lang = "python"
  netOn = false
  timeoutSec = 10
  runDir = getCurrentDir() / ".runs"

proc width(): int =
  result = terminalWidth()
  if result < 20 or result > 200: result = 80

proc rule() = echo "─".repeat(width())

proc banner() =
  let w = min(width(), 60)
  echo "┌" & "─".repeat(w - 2) & "┐"
  for l in ["Compute Sandbox - Nim TUI", "python | js | sql   timeout " & $timeoutSec & "s   net " & (if netOn: "ON" else: "off (soft guard)")]:
    echo "│ " & l & " ".repeat(max(0, w - 4 - l.runeLen)) & " │"
  echo "└" & "─".repeat(w - 2) & "┘"
  echo "Enter code in the current language (" & lang & "). A line with just '.' runs it. ':help' for commands."

proc runCode(lng, code: string): Run =
  createDir(runDir)
  let ext = case lng
            of "js": ".js"
            of "sql": ".sql"
            else: ".py"
  let src = runDir / ("snippet" & ext)
  let outp = runDir / "snippet.out"
  writeFile(src, code)
  writeFile(runDir / "guard.py", PyGuard)
  writeFile(runDir / "guard.js", JsGuard)
  removeFile(outp)
  result.lang = lng
  result.code = code
  let t0 = epochTime()
  let redir = " > " & quoteShell(outp) & " 2>&1 < /dev/null"
  var cmd: string
  case lng
  of "js":
    let req = if netOn: "" else: " --require " & quoteShell(runDir / "guard.js")
    cmd = "exec node" & req & " " & quoteShell(src) & redir
  of "sql":
    # persistent db across runs, like a mounted session filesystem
    cmd = "exec sqlite3 -header -column " & quoteShell(runDir / "session.db") & " < " &
          quoteShell(src) & " > " & quoteShell(outp) & " 2>&1"
  else:
    if netOn:
      cmd = "exec python3 -u " & quoteShell(src) & redir
    else:
      cmd = "exec python3 -u " & quoteShell(runDir / "guard.py") & " " & quoteShell(src) & redir
  # exec so the timeout kill hits the interpreter itself, not just a wrapper shell
  let p = startProcess("/bin/sh", args = ["-c", cmd], options = {poUsePath})
  discard p.waitForExit(timeoutSec * 1000)
  if p.running:
    p.kill()
    discard p.waitForExit()
  result.exitCode = p.peekExitCode()
  p.close()
  result.secs = epochTime() - t0
  # killed by our timeout => SIGKILL (137) at/after the deadline
  result.timedOut = result.exitCode == 137 and result.secs >= float(timeoutSec) - 0.1
  if fileExists(outp):
    result.output = readFile(outp)
    if result.output.len > MaxOutput:
      result.output = result.output[0 ..< MaxOutput] & "\n[output truncated]"

proc show(r: Run) =
  rule()
  if r.output.len > 0:
    stdout.write r.output
    if not r.output.endsWith("\n"): echo ""
  rule()
  let status =
    if r.timedOut: "TIMED OUT after " & $timeoutSec & "s"
    elif r.exitCode == 0: "ok"
    else: "exit " & $r.exitCode
  echo status & "  (" & formatFloat(r.secs, ffDecimal, 2) & "s)"

proc help() =
  echo """Commands (only when no code is pending):
  :help          this text
  :history       list previous runs
  :show N        show output of run N
  :rerun N       run snippet N again
  :lang L        python | js | sql  (sql keeps tables in .runs/session.db)
  :net on|off    network access; off = soft guard, not a security boundary
  :timeout S     set timeout in seconds
  :clear         discard pending code (also works mid-entry)
  :quit          exit (also Ctrl+D / Ctrl+C)"""

proc record(r: Run) =
  history.add r
  if history.len > MaxHistory: history.delete(0)

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
    else:
      let r = runCode(history[i - 1].lang, history[i - 1].code)
      record r
      show r
  of ":timeout":
    try:
      let s = parseInt(arg)
      if s < 1 or s > 600: echo "timeout must be 1..600" else:
        timeoutSec = s
        echo "timeout = " & $s & "s"
    except ValueError: echo "usage: :timeout SECONDS"
  of ":lang":
    if arg in ["python", "js", "sql"]:
      lang = arg
      echo "language = " & lang
    else: echo "usage: :lang python|js|sql (now " & lang & ")"
  of ":net":
    if arg == "on": netOn = true
    elif arg == "off": netOn = false
    else: echo "usage: :net on|off"
    echo "net = " & (if netOn: "ON" else: "off (soft guard)")
  of ":clear": discard
  else: echo "unknown command " & parts[0] & " (:help)"
  true

proc onSigint() {.noconv.} =
  echo "\nbye"
  quit(130)

when isMainModule:
  if findExe("python3") == "":
    stderr.writeLine "python3 not found on PATH"
    quit(1)
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
    if t == "." :
      if buf.len == 0: continue
      let r = runCode(lang, buf.join("\n") & "\n")
      buf.setLen(0)
      record r
      show r
    elif t == ":clear":
      buf.setLen(0)
      echo "(cleared)"
    elif buf.len == 0 and t.startsWith(":"):
      if not command(t): break
    else:
      buf.add line
