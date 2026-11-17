#!/usr/bin/env python3
"""Chunked test origin; a file barrier makes flush checks deterministic."""
import http.server
import pathlib
import re
import sys
import time
import urllib.parse

root = pathlib.Path(sys.argv[2])

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def handle(self):
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        match = re.search(r"id=([a-zA-Z0-9_]+)", self.path)
        key = match.group(1) if match else "none"
        body = (root / "stream-body").read_bytes()
        args = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        chunked = args.get("known") != ["1"]
        first = body[:4096]
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
        else:
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.write_part(first, chunked)
            self.wfile.flush()
            deadline = time.monotonic() + 8
            while not (root / ("release-" + key)).exists():
                if time.monotonic() > deadline:
                    return
                time.sleep(0.01)
            for offset in range(len(first), len(body), 3073):
                part = body[offset:offset + 3073]
                self.write_part(part, chunked)
                self.wfile.flush()
            if chunked:
                self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def write_part(self, data, chunked):
        if chunked:
            self.wfile.write(("%x\r\n" % len(data)).encode() + data + b"\r\n")
        else:
            self.wfile.write(data)

server = http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
server.daemon_threads = True
server.serve_forever()
