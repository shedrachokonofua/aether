#!/usr/bin/env python3
"""Controlled L7 canary for estate-scanner Nuclei."""

from __future__ import annotations

import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MARKER = b"aether-estate-scan-fixture-ok\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(MARKER)))
        self.end_headers()
        self.wfile.write(MARKER)

    def log_message(self, format: str, *args) -> None:  # noqa: A003
        return


def main() -> None:
    bind = os.environ.get("ESTATE_FIXTURE_BIND", "127.0.0.1")
    port = int(os.environ.get("ESTATE_FIXTURE_PORT", "18080"))
    server = ThreadingHTTPServer((bind, port), Handler)
    print(f"estate-scan fixture listening on http://{bind}:{port}/", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
