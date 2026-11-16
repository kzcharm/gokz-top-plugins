"""Local-only HTTP fixture for web_bridge_http.sp; no API keys or game writes."""

import json
import socket
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Fixture(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert self.headers["X-Bridge-Key"] == "fixture-not-a-secret"
        assert self.headers["X-Bridge-Server"] == "fixture:10000"
        assert self.headers["Content-Type"] == "application/json"
        if self.path == "/reset":
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return
        if self.path in ("/timeout", "/waiting"):
            time.sleep(4)
        if self.path == "/waiting":
            assert body["wait"] is True
        if self.path == "/redirect":
            self.send_response(307)
            self.send_header("Location", "http://localhost:18093/redirected")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/large":
            assert body["padding"] == "x" * 150000
            assert body["unicode"] == "玩家 ✓"
        if self.path == "/disabled":
            assert body["enabled"] is False
        try:
            self.send_response(503 if self.path == "/error" else 200)
            self.send_header("Content-Type", "application/json")
            payload = b"" if self.path == "/empty" else b'{"ok":true}'
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 18093), Fixture).serve_forever()
