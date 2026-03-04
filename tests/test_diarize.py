"""Unit tests for speaker diarization helpers."""

import fcntl
import json
import os
import subprocess
from unittest.mock import MagicMock, patch

import numpy as np
import pytest

from meeting_transcriber.diarize import (
    TimestampedSegment,
    _resolve_hf_token,
    assign_speakers,
    cosine_similarity,
    format_diarized_transcript,
    load_speaker_db,
    match_speakers,
    save_speaker_db,
)


class TestCosineSimilarity:
    def test_identical_vectors(self):
        v = np.array([1.0, 2.0, 3.0])
        assert cosine_similarity(v, v) == pytest.approx(1.0)

    def test_orthogonal_vectors(self):
        a = np.array([1.0, 0.0])
        b = np.array([0.0, 1.0])
        assert cosine_similarity(a, b) == pytest.approx(0.0)

    def test_opposite_vectors(self):
        a = np.array([1.0, 0.0])
        b = np.array([-1.0, 0.0])
        assert cosine_similarity(a, b) == pytest.approx(-1.0)

    def test_zero_vector_returns_zero(self):
        a = np.array([0.0, 0.0])
        b = np.array([1.0, 2.0])
        assert cosine_similarity(a, b) == 0.0
        assert cosine_similarity(b, a) == 0.0


class TestAssignSpeakers:
    def test_assigns_by_max_overlap(self):
        segments = [TimestampedSegment(start=0.0, end=5.0, text="hello")]
        turns = [(0.0, 3.0, "Alice"), (3.0, 10.0, "Bob")]
        result = assign_speakers(segments, turns)
        # 0-3 overlaps with Alice (3s), 3-5 overlaps with Bob (2s)
        assert result[0].speaker == "Alice"

    def test_no_overlap_assigns_unknown(self):
        segments = [TimestampedSegment(start=10.0, end=15.0, text="late")]
        turns = [(0.0, 5.0, "Alice")]
        result = assign_speakers(segments, turns)
        assert result[0].speaker == "UNKNOWN"

    def test_exact_boundary(self):
        segments = [TimestampedSegment(start=5.0, end=10.0, text="mid")]
        turns = [(0.0, 5.0, "Alice"), (5.0, 10.0, "Bob")]
        result = assign_speakers(segments, turns)
        assert result[0].speaker == "Bob"

    def test_multiple_segments(self):
        segments = [
            TimestampedSegment(start=0.0, end=3.0, text="first"),
            TimestampedSegment(start=5.0, end=8.0, text="second"),
        ]
        turns = [(0.0, 4.0, "Alice"), (4.0, 9.0, "Bob")]
        result = assign_speakers(segments, turns)
        assert result[0].speaker == "Alice"
        assert result[1].speaker == "Bob"


class TestMatchSpeakers:
    def test_match_above_threshold(self):
        emb = {"SPEAKER_00": np.array([1.0, 0.0, 0.0])}
        db = {"Alice": [1.0, 0.0, 0.0]}
        mapping = match_speakers(emb, db)
        assert mapping["SPEAKER_00"] == "Alice"

    def test_no_match_below_threshold(self):
        emb = {"SPEAKER_00": np.array([1.0, 0.0, 0.0])}
        db = {"Alice": [0.0, 1.0, 0.0]}  # orthogonal → similarity 0
        mapping = match_speakers(emb, db)
        assert mapping["SPEAKER_00"] == "SPEAKER_00"

    def test_empty_db(self):
        emb = {"SPEAKER_00": np.array([1.0, 0.0])}
        mapping = match_speakers(emb, {})
        assert mapping["SPEAKER_00"] == "SPEAKER_00"

    def test_names_not_reused(self):
        """Each saved name can only match one speaker."""
        emb = {
            "SPEAKER_00": np.array([1.0, 0.0]),
            "SPEAKER_01": np.array([0.99, 0.1]),
        }
        db = {"Alice": [1.0, 0.0]}
        mapping = match_speakers(emb, db)
        # One gets Alice, the other stays as-is
        alice_count = sum(1 for v in mapping.values() if v == "Alice")
        assert alice_count == 1


class TestFormatDiarizedTranscript:
    def test_groups_consecutive_speakers(self):
        segments = [
            TimestampedSegment(0, 2, "Hello", speaker="Alice"),
            TimestampedSegment(2, 4, "there", speaker="Alice"),
            TimestampedSegment(4, 6, "Hi!", speaker="Bob"),
        ]
        result = format_diarized_transcript(segments)
        assert "[Alice]" in result
        assert "[Bob]" in result
        # Speaker label shown on every line
        assert result.count("[Alice]") == 2

    def test_empty_segments(self):
        assert format_diarized_transcript([]) == ""


class TestSpeakerDbFileLocking:
    def test_save_uses_exclusive_lock(self, tmp_path):
        db_path = tmp_path / "speakers.json"
        db = {"Alice": [0.1, 0.2, 0.3]}

        with patch("meeting_transcriber.diarize.fcntl") as mock_fcntl:
            mock_fcntl.LOCK_EX = fcntl.LOCK_EX
            mock_fcntl.LOCK_UN = fcntl.LOCK_UN
            # Let flock pass through so the real file I/O works
            mock_fcntl.flock = fcntl.flock
            save_speaker_db(db, db_path)

        # Verify file was written correctly
        saved = json.loads(db_path.read_text())
        assert saved == {"Alice": [0.1, 0.2, 0.3]}

    def test_save_creates_parent_dirs(self, tmp_path):
        db_path = tmp_path / "sub" / "dir" / "speakers.json"
        save_speaker_db({"Bob": [1.0]}, db_path)
        assert db_path.exists()

    def test_load_uses_shared_lock(self, tmp_path):
        db_path = tmp_path / "speakers.json"
        db_path.write_text(json.dumps({"Alice": [0.1, 0.2]}))

        with patch("meeting_transcriber.diarize.fcntl") as mock_fcntl:
            mock_fcntl.LOCK_SH = fcntl.LOCK_SH
            mock_fcntl.LOCK_UN = fcntl.LOCK_UN
            mock_fcntl.flock = fcntl.flock
            result = load_speaker_db(db_path)

        assert "Alice" in result

    def test_load_nonexistent_returns_empty(self, tmp_path):
        result = load_speaker_db(tmp_path / "does_not_exist.json")
        assert result == {}

    def test_load_merges_case_duplicates(self, tmp_path):
        db_path = tmp_path / "speakers.json"
        db_path.write_text(json.dumps({"alice": [1.0, 0.0], "ALICE": [0.0, 1.0]}))
        result = load_speaker_db(db_path)
        # Should merge into single "Alice" entry
        assert len(result) == 1
        assert "Alice" in result
        # Average of [1,0] and [0,1] = [0.5, 0.5]
        assert result["Alice"] == pytest.approx([0.5, 0.5])

    def test_load_capitalizes_multi_word_names(self, tmp_path):
        db_path = tmp_path / "speakers.json"
        db_path.write_text(
            json.dumps({"roman passler": [1.0, 0.0], "tobias jaschke": [0.0, 1.0]})
        )
        result = load_speaker_db(db_path)
        assert "Roman Passler" in result
        assert "Tobias Jaschke" in result
        assert "roman passler" not in result

    def test_load_merges_multi_word_case_duplicates(self, tmp_path):
        db_path = tmp_path / "speakers.json"
        db_path.write_text(
            json.dumps({"Roman": [1.0, 0.0], "roman passler": [0.0, 1.0]})
        )
        result = load_speaker_db(db_path)
        # "Roman" and "roman passler" are different keys, both should exist
        assert "Roman" in result
        assert "Roman Passler" in result

    def test_save_roundtrip(self, tmp_path):
        db_path = tmp_path / "speakers.json"
        original = {"Alice": [0.1, 0.2], "Bob": [0.3, 0.4]}
        save_speaker_db(original, db_path)
        loaded = load_speaker_db(db_path)
        assert loaded == original


class TestResolveHFToken:
    def test_env_var_takes_priority(self, monkeypatch):
        monkeypatch.setenv("HF_TOKEN", "hf_from_env")
        assert _resolve_hf_token() == "hf_from_env"

    def test_dotenv_fallback(self, monkeypatch):
        monkeypatch.delenv("HF_TOKEN", raising=False)

        # Simulate load_dotenv setting the env var from a .env file
        def fake_load_dotenv():
            os.environ["HF_TOKEN"] = "hf_from_dotenv"

        with patch("dotenv.load_dotenv", side_effect=fake_load_dotenv):
            assert _resolve_hf_token() == "hf_from_dotenv"

    @patch("meeting_transcriber.diarize.subprocess.run")
    def test_keychain_fallback(self, mock_run, monkeypatch):
        monkeypatch.delenv("HF_TOKEN", raising=False)
        # Patch load_dotenv to do nothing (no .env file)
        with patch("dotenv.load_dotenv"):
            mock_run.return_value = MagicMock(returncode=0, stdout="hf_from_keychain\n")
            token = _resolve_hf_token()
        assert token == "hf_from_keychain"
        mock_run.assert_called_once()

    @patch("meeting_transcriber.diarize.subprocess.run")
    def test_raises_when_all_fail(self, mock_run, monkeypatch):
        monkeypatch.delenv("HF_TOKEN", raising=False)
        with patch("dotenv.load_dotenv"):
            mock_run.return_value = MagicMock(returncode=44, stdout="")
            with pytest.raises(RuntimeError, match="HF_TOKEN not set"):
                _resolve_hf_token()

    @patch("meeting_transcriber.diarize.subprocess.run")
    def test_keychain_timeout_falls_through(self, mock_run, monkeypatch):
        monkeypatch.delenv("HF_TOKEN", raising=False)
        with patch("dotenv.load_dotenv"):
            mock_run.side_effect = subprocess.TimeoutExpired(cmd="security", timeout=5)
            with pytest.raises(RuntimeError, match="HF_TOKEN not set"):
                _resolve_hf_token()
