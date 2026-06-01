#!/usr/bin/env python3
"""Generate the GitHub social-preview card (docs/social-preview.png).

The card is pure vector graphics: this script emits an SVG and rasterizes it
with `rsvg-convert` (Homebrew: `brew install librsvg`). No image-generation
model involved — text stays crisp, the file stays tiny, and every element is
editable here rather than baked into a bitmap.

The waveform is computed, not hand-placed: each bar's height comes from a sum
of three out-of-phase sine waves (a single sine looks like a regular swell;
layering uneven frequencies reads as real audio), and each bar's colour is a
linear interpolation along a blue -> purple -> green ramp keyed to its x
position.

Usage:
    python3 scripts/generate_social_preview.py

Output is 1280x640 PNG (GitHub's recommended social-preview size), written to
docs/social-preview.png. Upload it via Repo -> Settings -> General ->
Social preview (there is no API for the social-preview image).
"""

import math
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

W, H = 1280, 640

# Accent ramp endpoints (RGB).
BLUE = (91, 141, 239)
PURPLE = (139, 92, 246)
GREEN = (34, 197, 94)


def _lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def _hexcol(r: float, g: float, b: float) -> str:
    return f"#{round(r):02x}{round(g):02x}{round(b):02x}"


def _ramp(t: float) -> str:
    """Interpolate blue -> purple -> green for t in [0, 1]."""
    if t < 0.5:
        u = t / 0.5
        return _hexcol(_lerp(BLUE[0], PURPLE[0], u),
                       _lerp(BLUE[1], PURPLE[1], u),
                       _lerp(BLUE[2], PURPLE[2], u))
    u = (t - 0.5) / 0.5
    return _hexcol(_lerp(PURPLE[0], GREEN[0], u),
                   _lerp(PURPLE[1], GREEN[1], u),
                   _lerp(PURPLE[2], GREEN[2], u))


def _waveform(n: int = 104, center_y: float = 500.0) -> str:
    bars = []
    step = W / n
    for i in range(n):
        raw = (0.5 * math.sin(i * 0.5)
               + 0.3 * math.sin(i * 1.27 + 1.1)
               + 0.2 * math.sin(i * 0.31 + 2.3))
        h = 8 + 42 * abs(raw)
        x = i * step + (step - 6) / 2
        t = i / (n - 1)
        bars.append(
            f'<rect x="{x:.1f}" y="{center_y - h:.1f}" width="6" '
            f'height="{2 * h:.1f}" rx="3" fill="{_ramp(t)}" opacity="0.92"/>')
    return "\n  ".join(bars)


def build_svg() -> str:
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#0A0E1A"/>
      <stop offset="1" stop-color="#141B30"/>
    </linearGradient>
    <radialGradient id="glowP" cx="0.85" cy="0.15" r="0.6">
      <stop offset="0" stop-color="#8B5CF6" stop-opacity="0.30"/>
      <stop offset="1" stop-color="#8B5CF6" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="glowB" cx="0.05" cy="0.9" r="0.7">
      <stop offset="0" stop-color="#5B8DEF" stop-opacity="0.22"/>
      <stop offset="1" stop-color="#5B8DEF" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="{W}" height="{H}" fill="url(#bg)"/>
  <rect width="{W}" height="{H}" fill="url(#glowP)"/>
  <rect width="{W}" height="{H}" fill="url(#glowB)"/>
  <text x="80" y="104" font-family="Helvetica, Arial, sans-serif" font-size="24" font-weight="700" letter-spacing="5" fill="#7C89A8">OPEN-SOURCE · macOS · ON-DEVICE</text>
  <text x="76" y="212" font-family="Helvetica, Arial, sans-serif" font-size="92" font-weight="700" fill="#F4F7FF">Meeting Transcriber</text>
  <text x="80" y="300" font-family="Helvetica, Arial, sans-serif" font-size="40" font-weight="600" fill="#E4E9F7">Private meeting notes that never leave your Mac.</text>
  <text x="80" y="350" font-family="Helvetica, Arial, sans-serif" font-size="27" fill="#98A2BE">Auto-records Teams · Zoom · Webex  →  transcribe · diarize · summarize.</text>
  {_waveform()}
  <text x="80" y="620" font-family="Helvetica, Arial, sans-serif" font-size="24" font-weight="500" fill="#5E6A88">github.com/pasrom/meeting-transcriber</text>
</svg>'''


def main() -> int:
    rsvg = shutil.which("rsvg-convert")
    if rsvg is None:
        print("error: rsvg-convert not found — install with `brew install librsvg`",
              file=sys.stderr)
        return 1

    out_path = Path(__file__).resolve().parent.parent / "docs" / "social-preview.png"
    svg = build_svg()

    with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as tmp:
        tmp.write(svg)
        svg_path = tmp.name

    try:
        subprocess.run([rsvg, "-w", str(W), "-h", str(H), svg_path,
                        "-o", str(out_path)], check=True)
    finally:
        Path(svg_path).unlink(missing_ok=True)

    print(f"wrote {out_path} ({W}x{H})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
