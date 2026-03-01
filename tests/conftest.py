"""Shared fixtures and markers for tests."""

import sys
from pathlib import Path

import pytest
from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent.parent / ".env")

macos_only = pytest.mark.skipif(sys.platform != "darwin", reason="macOS only")
slow = pytest.mark.slow
