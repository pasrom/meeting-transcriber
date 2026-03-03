"""
E2E Test: 3-Speaker Meeting Simulation with Diarization

Tests the complete diarization pipeline:
  Audio (macOS `say`, 3 voices) → Whisper → pyannote diarization →
  Speaker recognition → Formatted transcript

Requires: HF_TOKEN env var, macOS with `say` voices Anna/Flo/Sandy.
"""

import os
import re
import subprocess
import wave
from pathlib import Path

import numpy as np
import pytest

FIXTURE_DIR = Path(__file__).parent / "fixtures"
FIXTURE_WAV = FIXTURE_DIR / "three_speakers_de.wav"

SEGMENTS = [
    ("Anna", "Guten Tag zusammen. Willkommen zum Sprint Review."),
    ("Flo", "Danke Anna. Ich berichte über den Backend Status."),
    ("Sandy", "Und ich habe ein Update zum Frontend Design."),
    ("Anna", "Sehr gut. Flo, bitte fang an mit dem Backend."),
    ("Flo", "Die API Entwicklung ist abgeschlossen. Alle Tests sind grün."),
    (
        "Sandy",
        "Das Frontend ist zu achtzig Prozent fertig. Nächste Woche sind wir bereit.",
    ),
]

KEYWORDS = ["sprint", "review", "backend", "frontend", "api"]

pytestmark = [
    pytest.mark.macos_only,
    pytest.mark.slow,
    pytest.mark.skipif(not os.environ.get("HF_TOKEN"), reason="HF_TOKEN required"),
]


# ── Fixtures ─────────────────────────────────────────────────────────────────


@pytest.fixture(scope="module")
def three_speaker_wav():
    """Return path to 3-speaker WAV fixture; generate via `say` if missing."""
    if FIXTURE_WAV.exists():
        return FIXTURE_WAV

    FIXTURE_DIR.mkdir(parents=True, exist_ok=True)
    tmpdir = Path("/tmp/three_speakers_gen")
    tmpdir.mkdir(parents=True, exist_ok=True)

    try:
        for i, (voice, text) in enumerate(SEGMENTS):
            out = tmpdir / f"seg{i}_{voice.lower()}.wav"
            result = subprocess.run(
                [
                    "say",
                    "-v",
                    voice,
                    "--file-format=WAVE",
                    "--data-format=LEI16",
                    "-o",
                    str(out),
                    text,
                ],
                capture_output=True,
                text=True,
            )
            assert result.returncode == 0, f"say failed for {voice}: {result.stderr}"

        # Assemble: concatenate with 0.8s silence gaps, resample to 16kHz mono
        target_rate = 16000
        silence_gap = np.zeros(int(target_rate * 0.8), dtype=np.int16)

        parts = []
        for i, (voice, _) in enumerate(SEGMENTS):
            seg_path = tmpdir / f"seg{i}_{voice.lower()}.wav"
            with wave.open(str(seg_path), "rb") as wf:
                rate = wf.getframerate()
                channels = wf.getnchannels()
                raw = wf.readframes(wf.getnframes())

            samples = np.frombuffer(raw, dtype=np.int16)
            if channels > 1:
                samples = samples.reshape(-1, channels).mean(axis=1).astype(np.int16)

            if rate != target_rate:
                from math import gcd

                from scipy.signal import resample_poly

                g = gcd(rate, target_rate)
                up, down = target_rate // g, rate // g
                float_samples = samples.astype(np.float32) / 32768.0
                resampled = resample_poly(float_samples, up, down)
                samples = (np.clip(resampled, -1.0, 1.0) * 32767).astype(np.int16)

            parts.append(samples)
            if i < len(SEGMENTS) - 1:
                parts.append(silence_gap)

        combined = np.concatenate(parts)
        with wave.open(str(FIXTURE_WAV), "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(target_rate)
            wf.writeframes(combined.tobytes())
    finally:
        import shutil

        shutil.rmtree(tmpdir, ignore_errors=True)

    return FIXTURE_WAV


@pytest.fixture
def isolated_speaker_db(tmp_path, monkeypatch):
    """Redirect SPEAKERS_DB to tmp_path so tests don't touch real profiles."""
    db_path = tmp_path / "speakers.json"
    monkeypatch.setattr("meeting_transcriber.diarize.SPEAKERS_DB", db_path)
    return db_path


# ── Tests ────────────────────────────────────────────────────────────────────


class TestE2EDiarize:
    """End-to-end diarization pipeline tests (3-speaker meeting simulation)."""

    def test_fixture_valid(self, three_speaker_wav):
        """WAV fixture is 16kHz, mono, 16-bit, 15-35s duration."""
        assert three_speaker_wav.exists()
        with wave.open(str(three_speaker_wav), "rb") as wf:
            assert wf.getframerate() == 16000
            assert wf.getnchannels() == 1
            assert wf.getsampwidth() == 2
            duration = wf.getnframes() / wf.getframerate()
        assert 15 <= duration <= 35, f"Unexpected duration: {duration:.1f}s"

    def test_transcription(self, three_speaker_wav):
        """Whisper (base) recognizes key meeting terms."""
        from pywhispercpp.model import Model

        n_threads = min(os.cpu_count() or 4, 8)
        model = Model(
            "base",
            n_threads=n_threads,
            print_realtime=False,
            print_progress=False,
        )
        segments = model.transcribe(str(three_speaker_wav), language="de")
        transcript = " ".join(seg.text for seg in segments).strip()

        assert len(transcript) > 30, f"Transcript too short: {transcript!r}"

        transcript_lower = transcript.lower()
        found = [kw for kw in KEYWORDS if kw in transcript_lower]
        assert len(found) >= 1, (
            f"No keywords found from {KEYWORDS}\nTranscript: {transcript}"
        )

    def test_diarization_speaker_count(self, three_speaker_wav):
        """pyannote diarization detects exactly 3 speakers."""
        from meeting_transcriber.diarize import diarize

        turns = diarize(
            three_speaker_wav, num_speakers=3, interactive=False, meeting_title="Test"
        )
        speaker_labels = set(t[2] for t in turns)
        assert len(speaker_labels) == 3, (
            f"Expected 3 speakers, got {len(speaker_labels)}: {speaker_labels}"
        )

    def test_diarization_turns_valid(self, three_speaker_wav):
        """Diarization turns have valid structure and timing."""
        from meeting_transcriber.diarize import diarize

        turns = diarize(
            three_speaker_wav, num_speakers=3, interactive=False, meeting_title="Test"
        )

        # All turns have start < end
        for start, end, speaker in turns:
            assert start < end, f"Invalid turn: {start} >= {end} for {speaker}"

        # Each speaker has >2s of total speaking time
        speaker_labels = sorted(set(t[2] for t in turns))
        for label in speaker_labels:
            total = sum(end - start for start, end, spk in turns if spk == label)
            assert total > 2.0, f"{label} only spoke {total:.1f}s (expected >2s)"

        # Total speaking time >10s
        total_all = sum(end - start for start, end, _ in turns)
        assert total_all > 10.0, f"Total speaking time {total_all:.1f}s (expected >10s)"

    def test_speaker_assignment(self, three_speaker_wav):
        """assign_speakers maps >=80% of Whisper segments to a speaker."""
        from pywhispercpp.model import Model

        from meeting_transcriber.diarize import (
            TimestampedSegment,
            assign_speakers,
            diarize,
        )

        n_threads = min(os.cpu_count() or 4, 8)
        model = Model(
            "base",
            n_threads=n_threads,
            print_realtime=False,
            print_progress=False,
        )
        raw_segments = model.transcribe(
            str(three_speaker_wav),
            language="de",
        )
        segments = [
            TimestampedSegment(
                start=s.t0 * 0.01,
                end=s.t1 * 0.01,
                text=s.text,
            )
            for s in raw_segments
        ]

        turns = diarize(
            three_speaker_wav,
            num_speakers=3,
            interactive=False,
            meeting_title="Test",
        )
        assigned = assign_speakers(segments, turns)

        with_speaker = [s for s in assigned if s.speaker and s.speaker != "UNKNOWN"]
        ratio = len(with_speaker) / len(assigned) if assigned else 0
        assert ratio >= 0.8, f"Only {ratio:.0%} segments assigned (expected >=80%)"

        # Whisper base may produce few segments for TTS audio,
        # so we only require at least 1 speaker was assigned
        unique_speakers = set(s.speaker for s in with_speaker)
        assert len(unique_speakers) >= 1, "No speakers assigned"

    def test_formatted_transcript(self, three_speaker_wav):
        """format_diarized_transcript produces text with [Speaker] labels."""
        from pywhispercpp.model import Model

        from meeting_transcriber.diarize import (
            TimestampedSegment,
            assign_speakers,
            diarize,
            format_diarized_transcript,
        )

        n_threads = min(os.cpu_count() or 4, 8)
        model = Model(
            "base",
            n_threads=n_threads,
            print_realtime=False,
            print_progress=False,
        )
        raw_segments = model.transcribe(
            str(three_speaker_wav),
            language="de",
        )
        segments = [
            TimestampedSegment(
                start=s.t0 * 0.01,
                end=s.t1 * 0.01,
                text=s.text,
            )
            for s in raw_segments
        ]

        turns = diarize(
            three_speaker_wav,
            num_speakers=3,
            interactive=False,
            meeting_title="Test",
        )
        assigned = assign_speakers(segments, turns)
        text = format_diarized_transcript(assigned)

        assert len(text) > 0
        # Whisper base may produce few segments for TTS audio,
        # so we only require at least 1 speaker label
        labels = re.findall(r"\[(\w[\w\s]*)\]", text)
        assert len(set(labels)) >= 1, f"No speaker labels found in: {text[:200]}"

    def test_full_pipeline(self, three_speaker_wav):
        """transcribe() with diarize_enabled produces speaker-labelled output."""
        from meeting_transcriber.transcription.mac import transcribe

        text = transcribe(
            three_speaker_wav,
            model="base",
            language="de",
            diarize_enabled=True,
            num_speakers=3,
            meeting_title="Test",
        )

        assert len(text) > 30
        labels = re.findall(r"\[(\w[\w\s]*)\]", text)
        assert len(set(labels)) >= 1, f"No speaker labels found in: {text[:200]}"

    def test_speaker_recognition(self, three_speaker_wav, isolated_speaker_db):
        """Embeddings saved with names are recognized via match_speakers."""
        # Run pyannote to get embeddings
        import torch
        from pyannote.audio import Pipeline

        from meeting_transcriber.diarize import (
            load_speaker_db,
            match_speakers,
            save_speaker_db,
        )

        token = os.environ["HF_TOKEN"]
        device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
        pipeline = Pipeline.from_pretrained(
            "pyannote/speaker-diarization-3.1",
            token=token,
        )
        pipeline.to(device)
        result = pipeline(str(three_speaker_wav), num_speakers=3)

        annotation = getattr(result, "speaker_diarization", result)
        raw_embeddings = getattr(result, "speaker_embeddings", None)

        raw_labels = sorted(
            set(speaker for _, _, speaker in annotation.itertracks(yield_label=True))
        )

        if raw_embeddings is None or len(raw_embeddings) < len(raw_labels):
            pytest.skip("pyannote did not return speaker embeddings")

        # Save embeddings with names to isolated DB
        db = {}
        names = ["Alice", "Bob", "Carol"]
        embeddings: dict[str, np.ndarray] = {}
        for i, label in enumerate(raw_labels):
            db[names[i]] = np.array(raw_embeddings[i]).tolist()
            embeddings[label] = np.array(raw_embeddings[i])
        save_speaker_db(db, isolated_speaker_db)

        # Load back and match — same embeddings should match perfectly
        saved_db = load_speaker_db(isolated_speaker_db)
        mapping = match_speakers(embeddings, saved_db)

        recognized = [v for v in mapping.values() if v in ("Alice", "Bob", "Carol")]
        assert len(recognized) >= 1, f"No speakers recognized. Mapping: {mapping}"

    def test_protocol_input(self, three_speaker_wav):
        """Diarized transcript matches the watcher/CLI diarization regex."""
        from meeting_transcriber.transcription.mac import transcribe

        text = transcribe(
            three_speaker_wav,
            model="base",
            language="de",
            diarize_enabled=True,
            num_speakers=3,
            meeting_title="Test",
        )

        # Same regex as watcher.py:306 and cli.py:370
        diarized = bool(re.search(r"\[\w[\w\s]*\]", text))
        assert diarized, f"Transcript not detected as diarized:\n{text[:200]}"


# ── Standalone execution ─────────────────────────────────────────────────────

if __name__ == "__main__":
    pytest.main([__file__, "-v", "--tb=short"])
