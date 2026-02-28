"""Unit tests for macOS audio helpers."""

import os
from pathlib import Path
from unittest.mock import patch

from meeting_transcriber.audio.mac import _find_swift_binary


class TestFindSwiftBinary:
    def test_env_var_valid(self, tmp_path):
        binary = tmp_path / "screencapture-audio"
        binary.write_text("#!/bin/sh\n")
        binary.chmod(0o755)

        with patch.dict(os.environ, {"PROCTAP_BINARY": str(binary)}):
            result = _find_swift_binary()
            assert result == binary

    def test_env_var_not_executable(self, tmp_path):
        binary = tmp_path / "screencapture-audio"
        binary.write_text("not executable")
        binary.chmod(0o644)

        with (
            patch.dict(os.environ, {"PROCTAP_BINARY": str(binary)}),
            patch("sys.prefix", str(tmp_path / "empty_venv")),
            patch("meeting_transcriber.audio.mac.shutil.which", return_value=None),
        ):
            result = _find_swift_binary()
            # Should skip env var (not executable) and fall through
            assert result is None

    def test_env_var_missing_file(self, tmp_path):
        with (
            patch.dict(os.environ, {"PROCTAP_BINARY": str(tmp_path / "nonexistent")}),
            patch("sys.prefix", str(tmp_path / "empty_venv")),
            patch("meeting_transcriber.audio.mac.shutil.which", return_value=None),
        ):
            result = _find_swift_binary()
            assert result is None

    def test_venv_path_found(self, tmp_path):
        # Create fake venv structure
        binary_dir = (
            tmp_path
            / "lib"
            / "python3.14"
            / "site-packages"
            / "proctap"
            / "swift"
            / "screencapture-audio"
            / ".build"
            / "arm64-apple-macosx"
            / "release"
        )
        binary_dir.mkdir(parents=True)
        binary = binary_dir / "screencapture-audio"
        binary.write_text("#!/bin/sh\n")
        binary.chmod(0o755)

        with (
            patch.dict(os.environ, {}, clear=False),
            patch("sys.prefix", str(tmp_path)),
            patch("shutil.which", return_value=None),
        ):
            # Remove PROCTAP_BINARY if set
            env = os.environ.copy()
            env.pop("PROCTAP_BINARY", None)
            with patch.dict(os.environ, env, clear=True):
                result = _find_swift_binary()
                assert result == binary

    def test_shutil_which_fallback(self, tmp_path):
        with (
            patch.dict(os.environ, {}, clear=False),
            patch("sys.prefix", str(tmp_path)),  # empty venv, no binary
        ):
            env = os.environ.copy()
            env.pop("PROCTAP_BINARY", None)
            with (
                patch.dict(os.environ, env, clear=True),
                patch(
                    "meeting_transcriber.audio.mac.shutil.which",
                    return_value="/usr/local/bin/screencapture-audio",
                ),
            ):
                result = _find_swift_binary()
                assert result == Path("/usr/local/bin/screencapture-audio")

    def test_nothing_found(self, tmp_path):
        with (
            patch.dict(os.environ, {}, clear=False),
            patch("sys.prefix", str(tmp_path)),
        ):
            env = os.environ.copy()
            env.pop("PROCTAP_BINARY", None)
            with (
                patch.dict(os.environ, env, clear=True),
                patch("meeting_transcriber.audio.mac.shutil.which", return_value=None),
            ):
                result = _find_swift_binary()
                assert result is None

    def test_env_var_takes_priority_over_venv(self, tmp_path):
        """Env var should be checked before venv paths."""
        env_binary = tmp_path / "env_binary"
        env_binary.write_text("#!/bin/sh\n")
        env_binary.chmod(0o755)

        # Also create a venv binary
        venv_dir = (
            tmp_path
            / "venv"
            / "lib"
            / "python3.14"
            / "site-packages"
            / "proctap"
            / "swift"
            / "screencapture-audio"
            / ".build"
            / "arm64-apple-macosx"
            / "release"
        )
        venv_dir.mkdir(parents=True)
        venv_binary = venv_dir / "screencapture-audio"
        venv_binary.write_text("#!/bin/sh\n")
        venv_binary.chmod(0o755)

        with (
            patch.dict(os.environ, {"PROCTAP_BINARY": str(env_binary)}),
            patch("sys.prefix", str(tmp_path / "venv")),
        ):
            result = _find_swift_binary()
            assert result == env_binary
