#!/usr/bin/env python3
"""
Tiny OpenAI-compatible proxy that injects Portkey auth headers.
Hermes → localhost:8765 → adds x-portkey-api-key + x-portkey-config → api.portkey.ai
"""
import os
import socketserver
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

import httpx

PORTKEY_API_KEY = os.environ.get("PORTKEY_API_KEY", "")
PORTKEY_CONFIG = os.environ.get("PORTKEY_CONFIG", "pc-gemini-85dd0b")
PORTKEY_BASE = "https://api.portkey.ai/v1"
PROXY_PORT = 8765


class ProxyHandler(BaseHTTPRequestHandler):
    def _proxy(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""

        headers = {
            "Content-Type": self.headers.get("Content-Type", "application/json"),
            "Accept": self.headers.get("Accept", "application/json"),
            "x-portkey-api-key": PORTKEY_API_KEY,
            "x-portkey-config": PORTKEY_CONFIG,
        }

        target = PORTKEY_BASE + self.path

        try:
            with httpx.Client(timeout=120) as client:
                resp = client.request(self.command, target, content=body, headers=headers)

            self.send_response(resp.status_code)
            for k, v in resp.headers.items():
                if k.lower() not in ("transfer-encoding", "connection", "content-encoding"):
                    self.send_header(k, v)
            self.end_headers()
            self.wfile.write(resp.content)

        except Exception as e:
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(f'{{"error": "{e}"}}'.encode())

    def do_POST(self):
        self._proxy()

    def do_GET(self):
        self._proxy()

    def log_message(self, fmt, *args):
        print(f"[portkey-proxy] {args[0]} {args[1]}", flush=True)


class ThreadedHTTPServer(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    print(f"[portkey-proxy] Starting on 127.0.0.1:{PROXY_PORT}", flush=True)
    print(f"[portkey-proxy] Routing to {PORTKEY_BASE} with config={PORTKEY_CONFIG}", flush=True)
    if not PORTKEY_API_KEY:
        print("[portkey-proxy] WARNING: PORTKEY_API_KEY is not set!", flush=True)
    ThreadedHTTPServer(("127.0.0.1", PROXY_PORT), ProxyHandler).serve_forever()
