#!/usr/bin/env python3
"""A deliberately strict cache backend, for testing the client.

Reads request bodies by `Content-Length` only — the way an object store
or a naive handler does, and the way pkfire's uploads used to fail
against: the body went out `Transfer-Encoding: chunked` with no length,
so this server stored a zero-byte object, returned 200, and every later
fetch got a well-formed empty archive.

Speaks the same layout as the reference Worker:

    GET|PUT <base>/cas/<key[0:2]>/<key[2:]>/entry.tar.gz

Usage: strict_cache_server.py <root-dir> [port]
"""
import http.server
import os
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8760


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _path(self):
        # Contain the write: a key is hex, but a bad one must not be
        # able to walk out of the store.
        rel = os.path.normpath(self.path.lstrip("/"))
        if rel.startswith("..") or os.path.isabs(rel):
            return None
        return os.path.join(ROOT, rel)

    def _empty(self, code):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_PUT(self):
        if "chunked" in (self.headers.get("Transfer-Encoding") or "").lower():
            # The whole point. Refuse loudly rather than storing nothing.
            self.send_response(411)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        path = self._path()
        if path is None:
            return self._empty(400)
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(body)
        self._empty(200)

    def do_GET(self):
        path = self._path()
        if path is None or not os.path.isfile(path):
            return self._empty(404)
        with open(path, "rb") as f:
            body = f.read()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", "application/octet-stream")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


os.makedirs(ROOT, exist_ok=True)
http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
