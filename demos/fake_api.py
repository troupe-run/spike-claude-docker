# Minimal stand-in for api.anthropic.com: records each request body to /log/<n>.json, returns 401.
# Lets us see exactly what claude would send (system prompt, tools, CLAUDE.md) with no credential.
import http.server, json, itertools, os, hashlib
n = itertools.count()
class H(http.server.BaseHTTPRequestHandler):
    def _h(self):
        body = self.rfile.read(int(self.headers.get("content-length") or 0))
        with open(f"/log/{next(n):03d}.json", "w") as f:
            auth = {k.lower(): hashlib.sha256(v.encode()).hexdigest()[:12] for k, v in self.headers.items() if k.lower() in ("x-api-key", "authorization")}
            json.dump({"path": self.path, "auth_sha256_12": auth, "headers": {k: ("<redacted>" if k.lower() in ("x-api-key", "authorization") else v) for k, v in self.headers.items()}, "body": body.decode(errors="replace")}, f)
        self.send_response(401); self.send_header("content-type", "application/json"); self.end_headers()
        self.wfile.write(b'{"type":"error","error":{"type":"authentication_error","message":"fake api"}}')
    do_GET = do_POST = _h
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
