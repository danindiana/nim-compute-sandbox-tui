# Execution core shared by sandbox_tui (REPL / one-shot CLI) and anything else that
# wants to run a snippet: python3, node or sqlite3 in a subprocess with
#   - a scrubbed environment (env -i),
#   - resource limits (prlimit: cpu, file size, open files, processes, address space),
#   - its own session directory (cwd, HOME, session.db) with a soft size quota,
#   - a timeout that kills the WHOLE process group (children included),
#   - a soft network guard (off | proxy | on); see README: not a security boundary.
import os, osproc, strutils, times, posix

const
  MaxOutput* = 20_000          # bytes of output kept per run
  PyGuard = """import socket as _s, os
_allow = os.environ.get("SANDBOX_ALLOW", "")
_ah, _, _ap = _allow.partition(":")
def _deny(*a, **k):
    raise OSError("network disabled in sandbox (use :net proxy or :net on)")
def _ok(addr):
    return bool(_allow) and isinstance(addr, tuple) and str(addr[0]) in (_ah, "localhost") and str(addr[1]) == _ap
_oc, _oce, _ogai = _s.socket.connect, _s.socket.connect_ex, _s.getaddrinfo
def _connect(self, addr):
    if not _ok(addr): _deny()
    return _oc(self, addr)
def _connect_ex(self, addr):
    if not _ok(addr): _deny()
    return _oce(self, addr)
def _gai(host, *a, **k):
    if not (_allow and host in (_ah, "localhost")): _deny()
    return _ogai(host, *a, **k)
_s.socket.connect = _connect
_s.socket.connect_ex = _connect_ex
_s.getaddrinfo = _gai
import runpy, sys
sys.argv = [sys.argv[1]]
runpy.run_path(sys.argv[0], run_name="__main__")
"""
  JsGuard = """const net = require('net'), dns = require('dns');
const allow = process.env.SANDBOX_ALLOW || '';
const [ah, ap] = [allow.split(':')[0], allow.split(':')[1]];
const deny = () => { throw new Error('network disabled in sandbox (use :net proxy or :net on)'); };
const hostOk = (h) => allow && (h === ah || h === 'localhost');
const origConnect = net.Socket.prototype.connect;
net.Socket.prototype.connect = function (...args) {
  let a = args[0], host, port;
  if (Array.isArray(a)) a = a[0];   // node passes pre-normalized [options, cb]
  if (a && typeof a === 'object') { host = a.host || 'localhost'; port = a.port; }
  else { port = a; host = typeof args[1] === 'string' ? args[1] : 'localhost'; }
  if (!hostOk(String(host)) || String(port) !== ap) deny();
  return origConnect.apply(this, args);
};
const origLookup = dns.lookup;
dns.lookup = function (host, ...rest) { if (!hostOk(String(host))) deny(); return origLookup.call(this, host, ...rest); };
"""

type
  Limits* = object
    fsizeMB*: int              # max size of any single file the snippet writes
    nofile*: int               # open file descriptors
    procMax*: int              # RLIMIT_NPROC; 0 = unset (see note in runCode)
    cpuSlackSec*: int          # CPU seconds allowed beyond the wall-clock timeout
  Sandbox* = ref object
    baseDir*: string           # parent of sessions/ and guard files
    session*: string
    netMode*: string           # off | proxy | on
    proxyAddr*: string
    timeoutSec*: int
    quotaMB*: int              # soft per-session quota (warning only)
    limits*: Limits
  Run* = object
    lang*, code*, output*: string
    exitCode*: int
    timedOut*, truncated*: bool
    secs*: float

proc newSandbox*(baseDir: string): Sandbox =
  Sandbox(baseDir: baseDir, session: "default", netMode: "off",
          proxyAddr: getEnv("SANDBOX_PROXY", "127.0.0.1:8899"), timeoutSec: 10, quotaMB: 50,
          limits: Limits(fsizeMB: 50, nofile: 256, procMax: 0, cpuSlackSec: 5))

proc validSession*(n: string): bool =
  n.len in 1 .. 32 and n.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '_', '-'})

proc sessionDir*(sb: Sandbox): string = sb.baseDir / "sessions" / sb.session

proc dirSize*(d: string): int64 =
  if not dirExists(d): return 0
  for f in walkDirRec(d, yieldFilter = {pcFile}):
    try: result += getFileSize(f)
    except OSError: discard

proc listSessions*(sb: Sandbox): seq[(string, int64)] =
  let d = sb.baseDir / "sessions"
  if dirExists(d):
    for kind, p in walkDir(d):
      if kind == pcDir: result.add (p.extractFilename, dirSize(p))

proc wipeSession*(sb: Sandbox) =
  let d = sb.sessionDir
  if dirExists(d) and d.startsWith(sb.baseDir / "sessions"): removeDir(d)

proc netLabel*(sb: Sandbox): string =
  case sb.netMode
  of "on": "ON (unrestricted)"
  of "proxy": "proxy " & sb.proxyAddr
  else: "off (soft guard)"

proc runCode*(sb: Sandbox, lng, code: string, onChunk: proc(s: string) = nil): Run =
  ## Runs one snippet. onChunk (optional) receives output as it appears.
  let sdir = sb.sessionDir
  createDir(sdir)
  createDir(sb.baseDir)
  let ext = case lng
            of "js": ".js"
            of "sql": ".sql"
            else: ".py"
  let src = sdir / ("snippet" & ext)
  let outp = sdir / "snippet.out"
  writeFile(src, code)
  writeFile(sb.baseDir / "guard.py", PyGuard)
  writeFile(sb.baseDir / "guard.js", JsGuard)
  removeFile(outp)
  result.lang = lng
  result.code = code

  # scrubbed environment: only what an interpreter needs (+ proxy vars in proxy mode)
  var envp = "env -i PATH=" & quoteShell(getEnv("PATH", "/usr/local/bin:/usr/bin:/bin")) &
             " HOME=" & quoteShell(sdir) & " LANG=C.UTF-8"
  if sb.netMode == "proxy":
    let pu = "http://" & sb.proxyAddr
    envp &= " SANDBOX_ALLOW=" & quoteShell(sb.proxyAddr) &
            " HTTP_PROXY=" & quoteShell(pu) & " HTTPS_PROXY=" & quoteShell(pu) &
            " http_proxy=" & quoteShell(pu) & " https_proxy=" & quoteShell(pu) &
            " NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost" &
            " SANDBOX_GATEWAY=" & quoteShell(pu & "/gw")
  # RLIMIT_NPROC is counted per *real uid across the whole host*, and threads count too; in a container
  # whose uid equals a busy host user's uid, any realistic cap breaks node (it needs ~10 threads). So it is
  # off by default and the container runtime's pids-limit is the real fork-bomb bound; :limits procs N opts in.
  let nprocFlag = if sb.limits.procMax > 0: " --nproc=" & $sb.limits.procMax else: ""
  # resource limits via prlimit (dash has no `ulimit -u`). Node/WebAssembly reserve many GB of
  # *virtual* address space (fetch dies under --as), so node gets no --as but a V8 heap cap instead.
  let asLimit = if lng == "js": "" else: " --as=" & $(2048 * 1024 * 1024)
  let lim = " prlimit --cpu=" & $(sb.timeoutSec + sb.limits.cpuSlackSec) &
            " --fsize=" & $(sb.limits.fsizeMB * 1024 * 1024) &
            " --nofile=" & $sb.limits.nofile &
            nprocFlag & asLimit
  # setsid => the interpreter leads its own process group, so we can kill the group
  let pre = "cd " & quoteShell(sdir) & " && exec" & lim & " setsid " & envp
  let redir = " > " & quoteShell(outp) & " 2>&1 < /dev/null"
  let guarded = sb.netMode != "on"
  var cmd: string
  case lng
  of "js":
    let req = if guarded: " --require " & quoteShell(sb.baseDir / "guard.js") else: ""
    cmd = pre & " node --max-old-space-size=512" & req & " " & quoteShell(src) & redir
  of "sql":
    # persistent per-session db, like a mounted session filesystem
    cmd = pre & " sqlite3 -header -column session.db < " & quoteShell(src) & " > " & quoteShell(outp) & " 2>&1"
  else:
    if guarded:
      cmd = pre & " python3 -u " & quoteShell(sb.baseDir / "guard.py") & " " & quoteShell(src) & redir
    else:
      cmd = pre & " python3 -u " & quoteShell(src) & redir

  let t0 = epochTime()
  let p = startProcess("/bin/sh", args = ["-c", cmd], options = {poUsePath})
  let pid = p.processID
  var pos = 0
  var acc = ""
  var truncd = false

  proc drain() =
    if not fileExists(outp): return
    let size = int(getFileSize(outp))
    if size > pos and acc.len < MaxOutput:
      var f: File
      if open(f, outp, fmRead):
        f.setFilePos(pos)
        let n = min(size - pos, MaxOutput - acc.len)
        var buf = newString(n)
        let got = f.readBuffer(addr buf[0], n)
        buf.setLen(got)
        f.close()
        pos += got
        acc.add buf
        if onChunk != nil and buf.len > 0: onChunk(buf)
    if size > pos and acc.len >= MaxOutput: truncd = true

  let deadline = t0 + float(sb.timeoutSec)
  while p.running:
    drain()
    if epochTime() >= deadline:
      result.timedOut = true
      break
    sleep(40)
  if result.timedOut:
    discard posix.kill(Pid(-pid), SIGKILL)       # whole group
    discard p.waitForExit()
  result.exitCode = p.peekExitCode()
  # reap anything left running in the group (background children of a finished snippet)
  discard posix.kill(Pid(-pid), SIGKILL)
  p.close()
  drain()
  result.secs = epochTime() - t0
  result.output = acc
  result.truncated = truncd
  if truncd: result.output.add "\n[output truncated]"

proc quotaWarning*(sb: Sandbox): string =
  let used = dirSize(sb.sessionDir)
  if used > int64(sb.quotaMB) * 1024 * 1024:
    result = "warning: session '" & sb.session & "' uses " & $(used div (1024 * 1024)) &
             " MB, over its " & $sb.quotaMB & " MB quota (:wipe to clear)"
