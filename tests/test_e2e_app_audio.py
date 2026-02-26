"""
E2E Test: App Audio Pipeline → Whisper Transcription

Tests the complete pipeline as the macOS transcriber runs it:
1. macOS `say` generates speech as WAV (simulates app output)
2. Audio is converted to ProcTap format (48kHz stereo float32 chunks)
3. Chunks go through the identical mix pipeline (stereo→mono, 48kHz WAV)
4. WAV is transcribed with pywhispercpp (whisper.cpp resamples internally)
5. Transcription is verified against the original text
6. ProcTap connection to a real app is verified separately
"""

import os
import subprocess
import time
import wave
from pathlib import Path
from tempfile import NamedTemporaryFile

import numpy as np
import pytest

APP_RATE = 48000
APP_CHANNELS = 2

TEXTS = {
    "de": (
        "Willkommen zum Meeting. Heute besprechen wir die neuen Projektziele "
        "und die Aufgabenverteilung für das nächste Quartal."
    ),
    "en": (
        "Welcome to the meeting. Today we will discuss the new project goals "
        "and the task distribution for the next quarter."
    ),
}

KEYWORDS = {
    "de": ["meeting", "projekt", "quartal"],
    "en": ["meeting", "project", "quarter"],
}

PLAYER_APP = "/tmp/TestAudioPlayer.app"
PLAYER_BINARY = PLAYER_APP + "/Contents/MacOS/player"


# ── Fixtures ─────────────────────────────────────────────────────────────────


@pytest.fixture(params=["de", "en"])
def lang(request):
    return request.param


@pytest.fixture
def speech_wav(lang):
    """Generate speech WAV via macOS `say`."""
    text = TEXTS[lang]
    voice = "Anna" if lang == "de" else "Samantha"
    tmp = NamedTemporaryFile(suffix=".wav", delete=False)
    wav_path = Path(tmp.name)
    tmp.close()

    result = subprocess.run(
        [
            "say",
            "-v",
            voice,
            "-o",
            str(wav_path),
            "--file-format=WAVE",
            "--data-format=LEI16",
            text,
        ],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, f"say failed: {result.stderr}"
    yield wav_path
    wav_path.unlink(missing_ok=True)


# ── Helpers ──────────────────────────────────────────────────────────────────


def convert_to_proctap_format(speech_path: Path) -> list[bytes]:
    """WAV → ProcTap-identical chunks (48kHz stereo float32)."""
    with wave.open(str(speech_path), "rb") as wf:
        orig_rate = wf.getframerate()
        orig_channels = wf.getnchannels()
        orig_sampwidth = wf.getsampwidth()
        nframes = wf.getnframes()
        raw = wf.readframes(nframes)

    if orig_sampwidth == 2:
        samples = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    elif orig_sampwidth == 4:
        samples = np.frombuffer(raw, dtype=np.int32).astype(np.float32) / 2147483648.0
    else:
        raise ValueError(f"Unknown sample width: {orig_sampwidth}")

    if orig_channels > 1:
        samples = samples.reshape(-1, orig_channels).mean(axis=1)

    if orig_rate != APP_RATE:
        new_len = int(len(samples) * APP_RATE / orig_rate)
        samples = np.interp(
            np.linspace(0, len(samples) - 1, new_len),
            np.arange(len(samples)),
            samples,
        )

    stereo = np.empty(len(samples) * APP_CHANNELS, dtype=np.float32)
    stereo[0::2] = samples
    stereo[1::2] = samples

    chunk_samples = APP_RATE * APP_CHANNELS * 10 // 1000
    chunks = []
    for i in range(0, len(stereo), chunk_samples):
        chunk = stereo[i : i + chunk_samples]
        if len(chunk) == chunk_samples:
            chunks.append(chunk.tobytes())
        else:
            padded = np.zeros(chunk_samples, dtype=np.float32)
            padded[: len(chunk)] = chunk
            chunks.append(padded.tobytes())

    return chunks


def mix_pipeline(frames_app: list[bytes]) -> Path:
    """Identical mix pipeline as audio.mac.record_audio()."""
    raw = np.frombuffer(b"".join(frames_app), dtype=np.float32)

    if APP_CHANNELS == 2 and len(raw) >= 2:
        raw = raw.reshape(-1, 2).mean(axis=1)

    # No resampling — save at native rate, whisper.cpp resamples internally
    audio_int16 = (np.clip(raw, -1.0, 1.0) * 32767).astype(np.int16)

    tmp = NamedTemporaryFile(suffix=".wav", delete=False)
    wav_path = Path(tmp.name)
    tmp.close()

    with wave.open(str(wav_path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(APP_RATE)
        wf.writeframes(audio_int16.tobytes())

    return wav_path


def ensure_player_app() -> None:
    """Build Swift audio player as macOS app (with bundle ID)."""
    if Path(PLAYER_BINARY).exists():
        return

    app_dir = Path(PLAYER_APP)
    (app_dir / "Contents" / "MacOS").mkdir(parents=True, exist_ok=True)

    (app_dir / "Contents" / "Info.plist").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"'
        ' "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0"><dict>\n'
        "  <key>CFBundleIdentifier</key><string>com.test.audioplayer</string>\n"
        "  <key>CFBundleName</key><string>TestAudioPlayer</string>\n"
        "  <key>CFBundleExecutable</key><string>player</string>\n"
        "</dict></plist>\n"
    )

    swift_src = Path("/tmp/player.swift")
    swift_src.write_text(
        "import AppKit\n"
        "import AVFoundation\n"
        "\n"
        "guard CommandLine.arguments.count > 1 else { exit(1) }\n"
        "let app = NSApplication.shared\n"
        "app.setActivationPolicy(.regular)\n"
        "let window = NSWindow(\n"
        "    contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),\n"
        "    styleMask: [], backing: .buffered, defer: false\n"
        ")\n"
        "window.orderFrontRegardless()\n"
        "\n"
        "let url = URL(fileURLWithPath: CommandLine.arguments[1])\n"
        "guard let player = try? AVAudioPlayer(contentsOf: url) else { exit(1) }\n"
        "player.numberOfLoops = 5\n"
        "player.play()\n"
        'fputs("PLAYING \\(player.duration)s\\n", stderr)\n'
        "DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) {\n"
        "    player.stop()\n"
        "    NSApp.terminate(nil)\n"
        "}\n"
        "app.run()\n"
    )

    result = subprocess.run(
        [
            "swiftc",
            "-o",
            PLAYER_BINARY,
            str(swift_src),
            "-framework",
            "AppKit",
            "-framework",
            "AVFoundation",
        ],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, f"Swift build failed: {result.stderr}"
    subprocess.run(
        ["codesign", "--force", "--sign", "-", PLAYER_APP], capture_output=True
    )


# ── Tests ────────────────────────────────────────────────────────────────────


@pytest.mark.macos_only
@pytest.mark.slow
class TestE2EAppAudio:
    """End-to-end test for the app audio → transcription pipeline."""

    def test_speech_generation(self, speech_wav):
        """Step 1: macOS `say` generates valid WAV."""
        assert speech_wav.exists()
        assert speech_wav.stat().st_size > 0

    def test_proctap_format_conversion(self, speech_wav):
        """Step 2: WAV converts to ProcTap format chunks."""
        chunks = convert_to_proctap_format(speech_wav)
        assert len(chunks) > 0
        for chunk in chunks:
            assert isinstance(chunk, bytes)
            assert len(chunk) > 0

    def test_mix_pipeline(self, speech_wav):
        """Step 3: Mix pipeline produces valid 48kHz WAV."""
        chunks = convert_to_proctap_format(speech_wav)
        wav_path = mix_pipeline(chunks)
        try:
            assert wav_path.exists()
            with wave.open(str(wav_path), "rb") as wf:
                assert wf.getframerate() == APP_RATE
                assert wf.getnchannels() == 1
                assert wf.getsampwidth() == 2
        finally:
            wav_path.unlink(missing_ok=True)

    def test_transcription(self, speech_wav, lang):
        """Step 4+5: Whisper transcription matches expected keywords."""
        from pywhispercpp.model import Model

        chunks = convert_to_proctap_format(speech_wav)
        wav_path = mix_pipeline(chunks)

        try:
            n_threads = min(os.cpu_count() or 4, 8)
            model = Model(
                "base",
                n_threads=n_threads,
                print_realtime=False,
                print_progress=False,
            )
            segments = model.transcribe(str(wav_path), language=lang)
            transcript = " ".join(seg.text for seg in segments).strip()

            keywords = KEYWORDS[lang]
            transcript_lower = transcript.lower()
            found = [kw for kw in keywords if kw.lower() in transcript_lower]

            assert len(found) >= len(keywords) // 2, (
                f"Too few keywords: {found} of {keywords}\nTranscript: {transcript}"
            )
        finally:
            wav_path.unlink(missing_ok=True)

    def test_proctap_live_capture(self, speech_wav):
        """Step 6: Real ProcTap capture receives audio data."""
        import threading

        from proctap import ProcessAudioCapture

        ensure_player_app()
        subprocess.run(["pkill", "-f", "TestAudioPlayer"], capture_output=True)
        time.sleep(0.3)
        subprocess.Popen(["open", "-a", PLAYER_APP, "--args", str(speech_wav)])
        time.sleep(2)

        r = subprocess.run(
            ["pgrep", "-n", "-f", "TestAudioPlayer"],
            capture_output=True,
            text=True,
        )
        if r.returncode != 0 or not r.stdout.strip():
            pytest.skip("Could not start player app")

        pid = int(r.stdout.strip().split()[-1])
        frames: list[bytes] = []
        stop = threading.Event()

        def on_data(pcm: bytes, frame_count: int) -> None:
            if not stop.is_set():
                frames.append(pcm)

        tap = ProcessAudioCapture(pid=pid, on_data=on_data)
        tap.start()
        time.sleep(5)
        stop.set()
        tap.close()

        subprocess.run(["pkill", "-f", "TestAudioPlayer"], capture_output=True)

        assert len(frames) > 0, (
            "No audio data received! "
            "Check: System Settings → Privacy & Security → Screen Recording"
        )

        raw = np.frombuffer(b"".join(frames), dtype=np.float32)
        peak = float(np.max(np.abs(raw)))
        assert peak > 0.001, "Audio is silence only"


# ── Standalone execution ─────────────────────────────────────────────────────

if __name__ == "__main__":
    pytest.main([__file__, "-v", "--tb=short"])
