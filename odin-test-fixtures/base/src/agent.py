"""Weather Digest — ODIN test fixture (clean control).

Deliberately offline: returns a static digest so the smoke test never
depends on an external weather API.
"""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 8080


def build_digest(city: str = "Aix-en-Provence") -> dict:
    return {
        "city": city,
        "summary": "Ensoleillé, 18°C, vent faible.",
        "source": "static-fixture",
    }


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
    # Binding all interfaces is required inside a container. nosec B104
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()  # nosec B104
