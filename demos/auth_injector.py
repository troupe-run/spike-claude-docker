# Credential-injecting reverse proxy (spike). Runs OUTSIDE the actor container (sidecar/host).
# The actor talks plain HTTP to it with a DUMMY credential; this replaces the auth header with
# the real one (read from a file only this process can see) and forwards upstream over TLS in
# production (UPSTREAM=https://api.anthropic.com); here UPSTREAM is the fake API.
import http.server, os, urllib.request, urllib.error
UPSTREAM = os.environ["UPSTREAM"]
TOKEN = open(os.environ["TOKEN_FILE"]).read().strip()
class H(http.server.BaseHTTPRequestHandler):
    def _h(self):
        body = self.rfile.read(int(self.headers.get("content-length") or 0)) or None
        hdrs = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "authorization", "x-api-key", "content-length")}
        hdrs["authorization"] = f"Bearer {TOKEN}"
        req = urllib.request.Request(UPSTREAM + self.path, data=body, headers=hdrs, method=self.command)
        try:
            r = urllib.request.urlopen(req, timeout=600); code, rh, data = r.status, r.headers, r.read()
        except urllib.error.HTTPError as e:
            code, rh, data = e.code, e.headers, e.read()
        self.send_response(code)
        for k, v in rh.items():
            if k.lower() not in ("transfer-encoding", "connection", "content-length"): self.send_header(k, v)
        self.send_header("content-length", str(len(data))); self.end_headers(); self.wfile.write(data)
    do_GET = do_POST = _h
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
