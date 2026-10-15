#!/usr/bin/env python3
"""Mock upstream for proxy tests: 200 only when the injected credential is present.
Never echoes the credential on /ok; /echo does (to test response redaction)."""
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = sys.argv[2]

class H(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="text/plain"):
        b = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        auth = self.headers.get("Authorization", "")
        if self.path.startswith("/ok"):
            self._send(200, "authorized") if auth == "Bearer " + TOKEN else self._send(401, "unauthorized")
        elif self.path.startswith("/echo"):
            self._send(200, "saw:" + auth)
        elif self.path.startswith("/big"):
            self._send(200, b"x" * 2_000_000)
        else:
            self._send(404, "nope")

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n)
        auth = self.headers.get("Authorization", "")
        self._send(200 if auth == "Bearer " + TOKEN else 401, "len=%d" % len(body))

    def log_message(self, *a):
        pass

ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
