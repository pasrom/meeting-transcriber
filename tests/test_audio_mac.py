"""Unit tests for macOS audio helpers."""

import os
from pathlib import Path
from unittest.mock import patch

from meeting_transcriber.audio.mac import _find_swift_binary


class TestFindSwiftBinary:
    def test_env_var_valid(self, tmp_path):
        binary = tmp_path / "audiotap"
        binary.write_text("#!/bin/sh\n")
        binary.chmod(0o755)

        with patch.dict(os.environ, {"AUDIOTAP_BINARY": str(binary)}):
            result = _find_swift_binary()
            assert result == binary

    def test_env_var_not_executable(self, tmp_path):
        binary = tmp_path / "audiotap"
        binary.write_text("not executable")
        binary.chmod(0o644)

        with (
            patch.dict(os.environ, {"AUDIOTAP_BINARY": str(binary)}),
            patch(
                "meeting_transcriber.audio.mac._project_search_anchors",
                return_value=[],
            ),
            patch("meeting_transcriber.audio.mac.shutil.which", return_value=None),
        ):
            result = _find_swift_binary()
            assert result is None

    def test_env_var_missing_file(self, tmp_path):
        with (
            patch.dict(os.environ, {"AUDIOTAP_BINARY": str(tmp_path / "nonexistent")}),
            patch(
                "meeting_transcriber.audio.mac._project_search_anchors",
                return_value=[],
            ),
            patch("meeting_transcriber.audio.mac.shutil.which", return_value=None),
        ):
            result = _find_swift_binary()
            assert result is None

    def test_project_local_path_found(self, tmp_path):
        # Create fake project-local build output
        binary_dir = tmp_path / "tools" / "audiotap" / ".build" / "release"
        binary_dir.mkdir(parents=True)
        binary = binary_dir / "audiotap"
        binary.write_text("#!/bin/sh\n")
        binary.chmod(0o755)

        env = os.environ.copy()
        env.pop("AUDIOTAP_BINARY", None)
        with (
            patch.dict(os.environ, env, clear=True),
            patch(
                "meeting_transcriber.audio.mac._project_search_anchors",
                return_value=[tmp_path / "dummy_file.py"],
            ),
            patch("meeting_transcriber.audio.mac.shutil.which", return_value=None),
        ):
            result = _find_swift_binary()
            assert result == binary

    def test_shutil_which_fallback(self, tmp_path):
        env = os.environ.copy()
        env.pop("AUDIOTAP_BINARY", None)
        with (
            patch.dict(os.environ, env, clear=True),
            patch(
                "meeting_transcriber.audio.mac._project_search_anchors",
                return_value=[],
            ),
            patch(
                "meeting_transcriber.audio.mac.shutil.which",
                return_value="/usr/local/bin/audiotap",
            ),
        ):
            result = _find_swift_binary()
            assert result == Path("/usr/local/bin/audiotap")

    def test_nothing_found(self, tmp_path):
        env = os.environ.copy()
        env.pop("AUDIOTAP_BINARY", None)
        with (
            patch.dict(os.environ, env, clear=True),
            patch(
                "meeting_transcriber.audio.mac._project_search_anchors",
                return_value=[],
            ),
            patch("meeting_transcriber.audio.mac.shutil.which", return_value=None),
        ):
            result = _find_swift_binary()
            assert result is None

    def test_env_var_takes_priority_over_project(self, tmp_path):
        """Env var should be checked before project-local paths."""
        env_binary = tmp_path / "env_binary"
        env_binary.write_text("#!/bin/sh\n")
        env_binary.chmod(0o755)

        # Also create a project-local binary
        proj_dir = tmp_path / "project" / "tools" / "audiotap" / ".build" / "release"
        proj_dir.mkdir(parents=True)
        proj_binary = proj_dir / "audiotap"
        proj_binary.write_text("#!/bin/sh\n")
        proj_binary.chmod(0o755)

        with (
            patch.dict(os.environ, {"AUDIOTAP_BINARY": str(env_binary)}),
            patch(
                "meeting_transcriber.audio.mac._project_search_anchors",
                return_value=[tmp_path / "project" / "src" / "dummy.py"],
            ),
        ):
            result = _find_swift_binary()
            assert result == env_binary
