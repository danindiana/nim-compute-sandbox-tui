# Egress proxy for the compute sandbox (Nim, stdlib; build with -d:ssl).
#
# Models the part of Perplexity's published Sandbox API design that says: sandboxes
# have no direct network; outbound traffic goes through a proxy OUTSIDE the sandbox
# that matches destination domains and injects credentials, so sandboxed code never
# sees raw keys.  Two ways to use it:
#   1. Gateway   GET|POST /gw/<alias>/<path>   -> proxy calls the configured upstream
#      over TLS and ADDS the configured headers (client-supplied auth is dropped).
#   2. CONNECT   CONNECT host:port             -> plain tunnel, domain/port allowlist
#      only (no injection: that would need TLS interception, deliberately not done).
#
# Secrets live only in the rules file (mode 600 enforced). They are never logged, and
# any occurrence of an injected value in an upstream response body is redacted.
# NOT a hardening claim by itself: secret isolation only holds if sandboxed code cannot
# read the rules file or reach the network any other way (see README, deployment).
import asyncdispatch, asyncnet, httpclient, json, net, nativesockets,
       os, strutils, tables, times, uri

const
  DefaultRules = "~/.config/sandbox-proxy/rules.json"
  MaxHead = 16 * 1024
  MaxHeaders = 100
  ReadTimeoutMs = 10_000
  UpstreamTimeoutMs = 20_000
  MaxClients = 64
  StripOnForward = ["authorization", "cookie", "host", "proxy-authorization", "x-api-key"]

type
  Gateway = object
    upstream: string
    inject: seq[(string, string)]
    methods: seq[string]
    maxBody: int
    maxResponse: int
  Rules = object
    host: string
    port: int
    allowDomains: seq[string]
    allowPorts: seq[int]
    gateways: Table[string, Gateway]

var
  rules: Rules
  clients = 0
  secretValues: seq[string]   # for response redaction

proc logLine(parts: varargs[string]) =
  stderr.writeLine now().format("HH:mm:ss") & " " & parts.join(" ")

# ---------------------------------------------------------------- rules

proc isLoopback(h: string): bool = h in ["127.0.0.1", "localhost", "::1"]

proc loadRules(path: string): Rules =
  let full = path.expandTilde
  if not fileExists(full):
    quit "rules file not found: " & full, 2
  let perms = getFilePermissions(full)
  if perms * {fpGroupRead, fpGroupWrite, fpGroupExec, fpOthersRead, fpOthersWrite, fpOthersExec} != {}:
    quit "refusing to start: " & full & " must be mode 600 (it holds credentials)", 2
  let j = parseFile(full)
  let listen = j{"listen"}.getStr("127.0.0.1:8899")
  let lp = listen.rsplit(':', 1)
  result.host = lp[0]
  result.port = parseInt(lp[1])
  for d in j{"allow_domains"}: result.allowDomains.add d.getStr().toLowerAscii
  if j.hasKey("allow_ports"):
    for p in j["allow_ports"]: result.allowPorts.add p.getInt()
  else:
    result.allowPorts = @[443]
  result.gateways = initTable[string, Gateway]()
  if j.hasKey("gateways"):
    for alias, g in j["gateways"]:
      if alias.len == 0 or not alias.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}):
        quit "bad alias name: " & alias, 2
      var gw = Gateway(upstream: g["upstream"].getStr().strip(chars = {'/'}, leading = false),
                       methods: @["GET", "POST"], maxBody: g{"max_body"}.getInt(1_000_000),
                       maxResponse: g{"max_response"}.getInt(5_000_000))
      let u = parseUri(gw.upstream)
      if not (u.scheme == "https" or (u.scheme == "http" and isLoopback(u.hostname))):
        quit "alias " & alias & ": upstream must be https (http only for loopback testing)", 2
      if g.hasKey("methods"):
        gw.methods = @[]
        for m in g["methods"]: gw.methods.add m.getStr().toUpperAscii
      if g.hasKey("inject"):
        for k, v in g["inject"]:
          if '\r' in k or '\n' in k or '\r' in v.getStr() or '\n' in v.getStr():
            quit "alias " & alias & ": CR/LF in inject header", 2
          gw.inject.add (k, v.getStr())
          if v.getStr().len >= 8: secretValues.add v.getStr()
          # also redact the bare token (value after "Bearer " etc.)
          let parts = v.getStr().splitWhitespace()
          if parts.len == 2 and parts[1].len >= 8: secretValues.add parts[1]
      result.gateways[alias] = gw

proc domainAllowed(host: string): tuple[ok: bool, exact: bool] =
  let h = host.toLowerAscii
  for d in rules.allowDomains:
    if d == h: return (true, true)
    if d.startsWith("*.") and h.endsWith(d[1 .. ^1]) and h.len > d.len - 1: return (true, false)
  (false, false)

proc privateV4(ip: string): bool =
  let p = ip.split('.')
  if p.len != 4: return true          # unknown format: treat as unsafe
  try:
    let a = parseInt(p[0]); let b = parseInt(p[1])
    return a == 10 or a == 127 or a == 0 or (a == 169 and b == 254) or
           (a == 172 and b in 16 .. 31) or (a == 192 and b == 168) or
           (a == 100 and b in 64 .. 127) or a >= 224
  except ValueError:
    return true

proc resolveV4(host: string, port: int): string =
  let ai = getAddrInfo(host, Port(port), AF_INET)
  if ai == nil: return ""
  result = getAddrString(ai.ai_addr)
  freeAddrInfo(ai)

# ---------------------------------------------------------------- http helpers

proc reply(c: AsyncSocket, code: int, reason, ctype, body: string) {.async.} =
  let head = "HTTP/1.1 " & $code & " " & reason & "\r\nContent-Type: " & ctype &
             "\r\nContent-Length: " & $body.len & "\r\nConnection: close\r\n\r\n"
  await c.send(head & body)

proc redact(s: string): string =
  result = s
  for v in secretValues:
    result = result.replace(v, "[REDACTED]")

proc badPath(rest: string): bool =
  if rest.len > 2048: return true
  for ch in rest:
    if ch < ' ' or ch == '\x7f' or ch == '\\' or ch == ' ': return true
  let lower = rest.toLowerAscii
  for bad in ["%2e", "%2f", "%5c", "%00", "%0d", "%0a"]:
    if bad in lower: return true
  for seg in rest.split('?')[0].split('/'):
    if seg == "..": return true
  false

# ---------------------------------------------------------------- gateway

proc toHttpMethod(m: string): HttpMethod =
  case m
  of "GET": HttpGet
  of "POST": HttpPost
  of "PUT": HttpPut
  of "PATCH": HttpPatch
  of "DELETE": HttpDelete
  of "HEAD": HttpHead
  of "OPTIONS": HttpOptions
  else: raise newException(ValueError, "unsupported method " & m)

proc handleGateway(c: AsyncSocket, meth, target: string, hdrs: seq[(string, string)],
                   clen: int) {.async.} =
  # target = /gw  or /gw/<alias>/<rest>
  if target == "/gw" or target == "/gw/":
    var names = newJArray()
    for a in rules.gateways.keys: names.add %a
    logLine("GW", "list", "200")
    await c.reply(200, "OK", "application/json", $(%*{"gateways": names}))
    return
  let rest0 = target[4 .. ^1]                       # after "/gw/"
  let slash = rest0.find('/')
  let alias = if slash < 0: rest0.split('?')[0] else: rest0[0 ..< slash]
  let tail = if slash < 0: "" else: rest0[slash .. ^1]
  if alias notin rules.gateways:
    logLine("GW", alias, "404 unknown alias")
    await c.reply(404, "Not Found", "text/plain", "unknown gateway alias\n")
    return
  let gw = rules.gateways[alias]
  if badPath(tail):
    logLine("GW", alias, "400 bad path")
    await c.reply(400, "Bad Request", "text/plain", "bad path\n")
    return
  if meth notin gw.methods:
    logLine("GW", alias, "405 method " & meth)
    await c.reply(405, "Method Not Allowed", "text/plain", "method not allowed for this gateway\n")
    return
  if clen > gw.maxBody:
    logLine("GW", alias, "413 body too large")
    await c.reply(413, "Payload Too Large", "text/plain", "request body too large\n")
    return
  var body = ""
  if clen > 0:
    let f = c.recv(clen)
    if not await withTimeout(f, ReadTimeoutMs):
      await c.reply(408, "Request Timeout", "text/plain", "body timeout\n")
      return
    body = f.read()
  # forward only a small safe set of client headers, then inject ours
  var fh = newHttpHeaders()
  for (k, v) in hdrs:
    let lk = k.toLowerAscii
    if lk in ["content-type", "accept", "user-agent"]:
      fh[k] = v
  for (k, v) in gw.inject: fh[k] = v
  let pathOnly = tail.split('?')[0]                 # logged without query string
  let url = gw.upstream & tail
  let client = newAsyncHttpClient(userAgent = "sandbox-egress-proxy/0.1", maxRedirects = 0)
  try:
    let fut = client.request(url, httpMethod = toHttpMethod(meth),
                             body = body, headers = fh)
    if not await withTimeout(fut, UpstreamTimeoutMs):
      logLine("GW", alias, pathOnly, "504 upstream timeout")
      await c.reply(504, "Gateway Timeout", "text/plain", "upstream timeout\n")
      return
    let resp = fut.read()
    let bf = resp.body
    if not await withTimeout(bf, UpstreamTimeoutMs):
      await c.reply(504, "Gateway Timeout", "text/plain", "upstream body timeout\n")
      return
    var rb = bf.read()
    if rb.len > gw.maxResponse:
      logLine("GW", alias, pathOnly, "502 response too large")
      await c.reply(502, "Bad Gateway", "text/plain", "upstream response too large\n")
      return
    rb = redact(rb)
    let ct = resp.headers.getOrDefault("content-type", @["application/octet-stream"].HttpHeaderValues)
    let code = resp.code.int
    logLine("GW", alias, meth, pathOnly, $code, $rb.len & "B")
    await c.reply(code, "Upstream", $ct, rb)
  except CatchableError as e:
    logLine("GW", alias, pathOnly, "502 " & e.msg.splitLines()[0])
    await c.reply(502, "Bad Gateway", "text/plain", "upstream error\n")
  finally:
    client.close()

# ---------------------------------------------------------------- CONNECT

proc pump(a, b: AsyncSocket) {.async.} =
  try:
    while true:
      # raw fd I/O: AsyncSocket.recv on a buffered socket waits for the full size
      let d = await recv(AsyncFD(a.getFd()), 65536)
      if d.len == 0: break
      await send(AsyncFD(b.getFd()), d)
  except CatchableError:
    discard
  a.close()
  b.close()

proc handleConnect(c: AsyncSocket, target: string) {.async.} =
  let hp = target.rsplit(':', 1)
  var port = 443
  if hp.len == 2:
    try: port = parseInt(hp[1])
    except ValueError: port = -1
  let host = hp[0].toLowerAscii
  let (ok, exact) = domainAllowed(host)
  if not ok or port notin rules.allowPorts:
    logLine("CONNECT", target, "403 not allowlisted")
    await c.reply(403, "Forbidden", "text/plain", "forbidden by egress policy\n")
    return
  let ip = resolveV4(host, port)
  if ip.len == 0:
    logLine("CONNECT", target, "502 dns failure")
    await c.reply(502, "Bad Gateway", "text/plain", "dns failure\n")
    return
  # wildcard matches must not resolve to private/loopback/metadata addresses
  if privateV4(ip) and not exact:
    logLine("CONNECT", target, "403 resolves to private address")
    await c.reply(403, "Forbidden", "text/plain", "forbidden by egress policy\n")
    return
  let up = newAsyncSocket()
  try:
    let f = up.connect(ip, Port(port))
    if not await withTimeout(f, UpstreamTimeoutMs):
      up.close()
      await c.reply(504, "Gateway Timeout", "text/plain", "connect timeout\n")
      return
    f.read()
  except CatchableError as e:
    up.close()
    logLine("CONNECT", target, "502 " & e.msg.splitLines()[0])
    await c.reply(502, "Bad Gateway", "text/plain", "connect failed\n")
    return
  logLine("CONNECT", target, "200 tunnel")
  await c.send("HTTP/1.1 200 Connection Established\r\n\r\n")
  asyncCheck pump(c, up)
  await pump(up, c)

# ---------------------------------------------------------------- server

proc handleClient(c: AsyncSocket) {.async.} =
  inc clients
  try:
    var lines: seq[string]
    var total = 0
    while true:
      let f = c.recvLine(maxLength = MaxHead)
      if not await withTimeout(f, ReadTimeoutMs):
        return
      let l = f.read()
      if l.len == 0 and lines.len == 0: return        # closed
      total += l.len
      if total > MaxHead or lines.len > MaxHeaders:
        await c.reply(431, "Request Header Fields Too Large", "text/plain", "headers too large\n")
        return
      if l == "\r\L" or l == "": break
      lines.add l.strip(chars = {'\r', '\L'}, leading = false)
    if lines.len == 0: return
    let rl = lines[0].splitWhitespace()
    if rl.len != 3 or not rl[2].startsWith("HTTP/1."):
      await c.reply(400, "Bad Request", "text/plain", "bad request line\n")
      return
    let meth = rl[0].toUpperAscii
    var target = rl[1]
    # absolute-form request addressed to this proxy itself (clients that proxy the gateway URL)
    for pre in ["http://127.0.0.1:" & $rules.port, "http://localhost:" & $rules.port,
                "http://" & rules.host & ":" & $rules.port]:
      if target.startsWith(pre & "/"):
        target = target[pre.len .. ^1]
        break
    var hdrs: seq[(string, string)]
    var clen = 0
    for l in lines[1 .. ^1]:
      let i = l.find(':')
      if i <= 0: continue
      let k = l[0 ..< i].strip
      let v = l[i + 1 .. ^1].strip
      hdrs.add (k, v)
      case k.toLowerAscii
      of "content-length":
        try: clen = parseInt(v)
        except ValueError:
          await c.reply(400, "Bad Request", "text/plain", "bad content-length\n")
          return
        if clen < 0:
          await c.reply(400, "Bad Request", "text/plain", "bad content-length\n")
          return
      of "transfer-encoding":
        await c.reply(400, "Bad Request", "text/plain", "chunked requests not supported\n")
        return
      else: discard
    if meth == "CONNECT":
      await handleConnect(c, target)
    elif target == "/gw" or target.startsWith("/gw/"):
      await handleGateway(c, meth, target, hdrs, clen)
    else:
      logLine(meth, target.split('?')[0], "403 not a gateway/CONNECT request")
      await c.reply(403, "Forbidden", "text/plain", "forbidden by egress policy\n")
  except CatchableError as e:
    logLine("ERR", e.msg.splitLines()[0])
  finally:
    dec clients
    c.close()

proc serve() {.async.} =
  let s = newAsyncSocket()
  s.setSockOpt(OptReuseAddr, true)
  s.bindAddr(Port(rules.port), rules.host)
  s.listen()
  logLine("listening on", rules.host & ":" & $rules.port, "|", $rules.gateways.len,
          "gateway(s),", $rules.allowDomains.len, "allowed domain(s)")
  while true:
    let c = await s.accept()
    if clients >= MaxClients:
      asyncCheck c.reply(503, "Service Unavailable", "text/plain", "busy\n")
      c.close()
    else:
      asyncCheck handleClient(c)

when isMainModule:
  var path = getEnv("SANDBOX_PROXY_RULES", DefaultRules)
  var listenOverride = ""
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "--listen" and i < paramCount():
      listenOverride = paramStr(i + 1); inc i
    elif a in ["-h", "--help"]:
      echo "usage: egress_proxy [--listen host:port] [rules.json]   (default rules: " & DefaultRules & ")"
      quit 0
    else: path = a
    inc i
  rules = loadRules(path)
  if listenOverride.len > 0:
    let lp = listenOverride.rsplit(':', 1)
    rules.host = lp[0]
    rules.port = parseInt(lp[1])
  waitFor serve()
