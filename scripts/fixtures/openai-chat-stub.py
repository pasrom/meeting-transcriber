#!/usr/bin/env python3
"""A local stand-in for an OpenAI-compatible chat-completions endpoint.

Used by the --protocol lane of scripts/e2e-app.sh, which points the app's
OpenAI-compatible protocol provider at this server so the protocol stage can be
asserted end to end without a real model, a network or an account.

It binds 127.0.0.1 on a port the kernel picks (never the app's RPC port), writes
that port to --port-file once it listens, and appends one JSON line per request
to --log: the method, path, content type and parsed body. No header beyond the
content type is logged: the lane runs with whatever API key the host has
configured, and a real key must never end up in a CI log.

What it answers is read from --mode-file on every request, so one server (and
one port, which the app reads only at launch) serves both phases of the lane:

  ok          200, a text/event-stream carrying --reply in two content deltas,
              a finish_reason "stop" chunk and the [DONE] sentinel, the shape
              OpenAIProtocolGenerator.parseSSELine consumes
  http500     500 with a JSON error body

Standard library only, so the lane needs nothing beyond the python3 Xcode ships.
"""

import argparse
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port-file", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--mode-file", required=True)
    parser.add_argument("--reply", required=True)
    return parser.parse_args()


ARGS = parse_args()


def read_mode():
    try:
        with open(ARGS.mode_file, encoding="utf-8") as handle:
            return handle.read().strip() or "ok"
    except OSError:
        return "ok"


def sse(payload):
    return ("data: " + payload + "\n\n").encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    # HTTP/1.0: the connection closes after each response, which is what ends
    # the client's line iterator over the stream.
    protocol_version = "HTTP/1.0"

    def log_message(self, *_):
        pass

    def _record(self, body_bytes, mode, status):
        try:
            body = json.loads(body_bytes.decode("utf-8")) if body_bytes else None
        except (UnicodeDecodeError, json.JSONDecodeError):
            body = None
        entry = {
            "method": self.command,
            "path": self.path,
            "contentType": self.headers.get("Content-Type", ""),
            "bodyBytes": len(body_bytes),
            "body": body,
            "mode": mode,
            "status": status,
        }
        with open(ARGS.log, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry, ensure_ascii=False) + "\n")

    def _send(self, status, content_type, chunks):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.end_headers()
        for chunk in chunks:
            self.wfile.write(chunk)
            self.wfile.flush()

    def _handle(self):
        length = int(self.headers.get("Content-Length") or 0)
        body_bytes = self.rfile.read(length) if length > 0 else b""
        mode = read_mode()
        if self.command != "POST" or not self.path.endswith("/chat/completions"):
            self._record(body_bytes, mode, 404)
            self._send(404, "application/json", [b'{"error":{"message":"not found"}}'])
            return
        if mode == "http500":
            self._record(body_bytes, mode, 500)
            self._send(500, "application/json", [b'{"error":{"message":"e2e stub: forced failure"}}'])
            return
        half = len(ARGS.reply) // 2
        parts = [ARGS.reply[:half], ARGS.reply[half:]]
        chunks = [sse(json.dumps({"choices": [{"index": 0, "delta": {"content": p}}]})) for p in parts]
        chunks.append(sse(json.dumps({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})))
        chunks.append(sse("[DONE]"))
        self._record(body_bytes, mode, 200)
        self._send(200, "text/event-stream", chunks)

    do_POST = _handle
    do_GET = _handle


def main():
    server = HTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    # Written only once the socket listens, and by rename, so a reader polling
    # for the file never sees a partial port.
    tmp = ARGS.port_file + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(str(port))
    os.replace(tmp, ARGS.port_file)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
