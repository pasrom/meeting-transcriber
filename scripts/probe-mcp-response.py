#!/usr/bin/env python3
"""Measure one Streamable HTTP MCP response with curl."""
import argparse
import getpass
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit


WIRE_LIMIT = 128 * 1024
RESULT_LIMIT = 32 * 1024
EVIDENCE_LIMIT = 16 * 1024
PROBE_LIMIT = 2 * 1024 * 1024
PROTOCOLS = {"2025-11-25", "2025-06-18", "2025-03-26"}


def response(data, expected_id):
    """Return the matching envelope and the body bytes through its SSE event."""
    if not data.lstrip().startswith((b"data:", b"event:", b":", b"id:", b"retry:")):
        envelope = json.loads(data)
        if isinstance(envelope, dict) and envelope.get("id") == expected_id:
            return envelope, len(data)
        raise ValueError("Response did not contain the expected JSON-RPC ID.")

    payload = []
    received = 0
    for line in [*data.splitlines(keepends=True), b""]:
        received += len(line)
        if line.startswith(b"data:"):
            payload.append(line[5:].strip())
        elif not line.strip() and payload:
            envelope = json.loads(b"\n".join(payload))
            if isinstance(envelope, dict) and envelope.get("id") == expected_id:
                return envelope, received
            payload.clear()
    raise ValueError("The SSE stream did not contain the expected JSON-RPC response.")


class Probe:
    def __init__(self, endpoint, folder, bearer):
        self.endpoint = endpoint
        self.folder = folder
        self.auth = folder / "headers"
        self.auth.write_text(f"Authorization: Bearer {bearer}\n" if bearer else "", encoding="utf-8")
        self.protocol = None
        self.session = None
        self.next_id = 1

    def request(self, method, params=None, notification=False):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        if not notification:
            message["id"] = self.next_id
            self.next_id += 1

        body = self.folder / "body"
        headers = self.folder / "response-headers"
        command = [
            "curl", "-q", "--silent", "--show-error", "--compressed", "--max-time", "30",
            "--max-filesize", str(PROBE_LIMIT), "--proto", "=https,http",
            "--header", "Accept: application/json, text/event-stream",
            "--header", "Content-Type: application/json", "--header", f"@{self.auth}",
            "--dump-header", str(headers), "--output", str(body), "--write-out", "%{http_code}",
        ]
        if self.protocol:
            command += ["--header", f"MCP-Protocol-Version: {self.protocol}"]
        if self.session:
            command += ["--header", f"Mcp-Session-Id: {self.session}"]
        result = subprocess.run(
            command + ["--data-binary", "@-", "--", self.endpoint],
            input=json.dumps(message).encode(), stdout=subprocess.PIPE, check=False,
        )
        if result.returncode == 63:
            raise ValueError(f"{method} exceeded the {PROBE_LIMIT:,}-byte probe download limit.")
        # An SSE server may leave the connection open after sending the reply.
        if result.returncode not in (0, 28):
            raise ValueError(f"{method} failed with curl exit code {result.returncode}.")
        if not 200 <= int(result.stdout or b"0") < 300:
            raise ValueError(f"{method} returned HTTP {result.stdout.decode() or 'unknown'}.")
        if notification:
            return None, 0
        if body.stat().st_size > PROBE_LIMIT:
            raise ValueError(f"{method} exceeded the {PROBE_LIMIT:,}-byte probe download limit.")
        for line in headers.read_bytes().splitlines():
            if line.lower().startswith(b"mcp-session-id:"):
                session = line.split(b":", 1)[1].strip().decode("ascii")
                if session and all(33 <= ord(character) <= 126 for character in session):
                    self.session = session
        envelope, size = response(body.read_bytes(), message["id"])
        if "error" in envelope or not isinstance(envelope.get("result"), dict):
            raise ValueError(f"{method} returned a JSON-RPC error or missing result.")
        return envelope["result"], size

    def initialize(self):
        hello, _ = self.request("initialize", {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "Meeting Transcriber response probe", "version": "1"},
        })
        self.protocol = hello.get("protocolVersion")
        if self.protocol not in PROTOCOLS:
            raise ValueError("The server selected an unsupported protocol version.")
        self.request("notifications/initialized", notification=True)

    def list_tools(self):
        params = {}
        for _ in range(4):
            result, _ = self.request("tools/list", params)
            for tool in result.get("tools", []):
                print(json.dumps({"name": tool["name"], "inputSchema": tool.get("inputSchema")}, ensure_ascii=False))
            cursor = result.get("nextCursor")
            if not cursor:
                return
            params = {"cursor": cursor}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("endpoint", help="Streamable HTTP MCP URL")
    parser.add_argument("tool", nargs="?", help="Read-only tool name. Omit to print tool names and schemas.")
    parser.add_argument("arguments", nargs="?", default="{}", help="Tool arguments as a JSON object")
    parser.add_argument("--bearer", action="store_true", help="Prompt for a provider-issued bearer token")
    args = parser.parse_args()

    try:
        url = urlsplit(args.endpoint)
        if not url.hostname or url.username or url.password or url.query or url.fragment or not (
            url.scheme == "https" or url.scheme == "http" and url.hostname in {"localhost", "127.0.0.1", "::1"}
        ):
            raise ValueError("Use HTTPS or loopback HTTP and omit URL credentials, query, and fragment.")
        arguments = json.loads(args.arguments)
        if not isinstance(arguments, dict):
            raise ValueError("Tool arguments must be a JSON object.")
        if args.bearer and not sys.stdin.isatty():
            raise ValueError("--bearer requires an interactive terminal.")
        bearer = getpass.getpass("MCP bearer token: ").strip() if args.bearer else ""
        if args.bearer and (not bearer or not all(33 <= ord(character) <= 126 for character in bearer)):
            raise ValueError("Enter a bearer token without spaces or line breaks.")
        with tempfile.TemporaryDirectory(prefix="mcp-probe-") as folder:
            probe = Probe(args.endpoint, Path(folder), bearer)
            probe.initialize()
            if args.tool:
                result, size = probe.request("tools/call", {"name": args.tool, "arguments": arguments})
                if result.get("isError"):
                    raise ValueError("The tool reported an error.")
                parts = []
                if isinstance(result.get("structuredContent"), dict):
                    parts.append({"structuredContent": result["structuredContent"]})
                parts.extend({"text": entry["text"]} for entry in result.get("content", [])
                             if entry.get("type") == "text" and entry.get("text"))
                normalized = len(json.dumps(parts, ensure_ascii=False, separators=(",", ":")).encode())
                print(f"Response through matching reply: {size:,} bytes (app wire cap {WIRE_LIMIT:,})")
                print(f"Approximate evidence content before filtering: {normalized:,} bytes")
                print(f"App result cap: {RESULT_LIMIT:,} bytes. Combined evidence cap: {EVIDENCE_LIMIT:,} bytes.")
            else:
                probe.list_tools()
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
