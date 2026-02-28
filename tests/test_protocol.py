"""Unit tests for protocol generation helpers."""

import json
import subprocess
import time
from unittest.mock import Mock, patch

from meeting_transcriber.protocol import _read_stream


class _FakeStdout:
    """Simulate subprocess stdout with line-by-line reads."""

    def __init__(self, lines: list[bytes]):
        self._lines = list(lines)
        self._index = 0

    def readline(self) -> bytes:
        if self._index >= len(self._lines):
            return b""
        line = self._lines[self._index]
        self._index += 1
        return line


def _make_proc(stdout_lines: list[bytes]) -> Mock:
    proc = Mock(spec=subprocess.Popen)
    proc.stdout = _FakeStdout(stdout_lines)
    proc.wait = Mock()
    proc.returncode = 0
    return proc


def _delta_line(text: str) -> bytes:
    obj = {"type": "content_block_delta", "delta": {"type": "text_delta", "text": text}}
    return json.dumps(obj).encode() + b"\n"


def _assistant_line(text: str) -> bytes:
    obj = {
        "type": "assistant",
        "message": {"content": [{"type": "text", "text": text}]},
    }
    return json.dumps(obj).encode() + b"\n"


class TestReadStream:
    def test_collects_text_deltas(self):
        lines = [_delta_line("Hello "), _delta_line("world")]
        proc = _make_proc(lines)
        result = _read_stream(proc)
        assert result == "Hello world"
        proc.wait.assert_called_once()

    def test_assistant_message_fallback(self):
        """If no streaming deltas, falls back to assistant message."""
        lines = [_assistant_line("Full protocol text")]
        proc = _make_proc(lines)
        result = _read_stream(proc)
        assert result == "Full protocol text"

    def test_assistant_ignored_when_deltas_present(self):
        """If deltas were streamed, assistant message is ignored."""
        lines = [
            _delta_line("Streamed"),
            _assistant_line("Should be ignored"),
        ]
        proc = _make_proc(lines)
        result = _read_stream(proc)
        assert result == "Streamed"

    def test_skips_malformed_json(self):
        lines = [
            b"not valid json\n",
            _delta_line("OK"),
        ]
        proc = _make_proc(lines)
        result = _read_stream(proc)
        assert result == "OK"

    def test_skips_empty_lines(self):
        lines = [b"\n", b"  \n", _delta_line("data")]
        proc = _make_proc(lines)
        result = _read_stream(proc)
        assert result == "data"

    def test_skips_unknown_event_types(self):
        unknown = json.dumps({"type": "system", "data": "ignored"}).encode() + b"\n"
        lines = [unknown, _delta_line("result")]
        proc = _make_proc(lines)
        result = _read_stream(proc)
        assert result == "result"

    def test_returns_empty_on_no_output(self):
        proc = _make_proc([])
        result = _read_stream(proc)
        assert result == ""

    def test_timeout_raises(self):
        """Timeout triggers when elapsed > TIMEOUT_SECONDS."""

        class _SlowStdout:
            def readline(self):
                time.sleep(0.01)
                return _delta_line("x")

        proc = Mock(spec=subprocess.Popen)
        proc.stdout = _SlowStdout()
        proc.wait = Mock()

        with patch("meeting_transcriber.protocol.TIMEOUT_SECONDS", 0):
            try:
                _read_stream(proc)
                assert False, "Expected TimeoutError"
            except TimeoutError:
                pass
