"""Teams mute detection via macOS Accessibility API.

Polls the Teams UI for the mute/unmute button state and records
transitions as a timeline that can be used to mask mic audio.

Requires: pip install pyobjc-framework-ApplicationServices
"""

import logging
import threading
import time
from dataclasses import dataclass

log = logging.getLogger(__name__)

# Mute-button description prefixes across locales (lowercase).
# Teams buttons have descriptions like "Mute (⌘ ⇧ M)" or "Unmute (⌘ ⇧ M)".
_MUTED_PREFIXES = ("unmute", "stummschaltung aufheben")  # button says "Unmute" → muted
_UNMUTED_PREFIXES = ("mute", "stummschalten")  # button says "Mute" → unmuted

# All known labels (for tests)
_MUTE_LABELS = {
    "mute",
    "unmute",
    "stummschalten",
    "stummschaltung aufheben",
}


@dataclass
class MuteTransition:
    """A point in time where the mute state changed."""

    timestamp: float  # time.monotonic() value
    is_muted: bool


def _is_accessibility_trusted() -> bool:
    """Check whether this process has Accessibility permission."""
    try:
        from ApplicationServices import AXIsProcessTrusted

        return bool(AXIsProcessTrusted())
    except Exception:
        return False


def _get_ax_attr(element, attr):
    """Read a single AX attribute. Returns value or None."""
    from ApplicationServices import (
        AXUIElementCopyAttributeValue,
        kAXErrorSuccess,
    )

    err, val = AXUIElementCopyAttributeValue(element, attr, None)
    return val if err == kAXErrorSuccess else None


def _find_mute_button(element, depth: int = 0, max_depth: int = 25):
    """Recursively search AX tree for a button whose description starts
    with a mute/unmute label.

    Teams (Electron) nests buttons deep in the web content — up to
    depth ~20.  Buttons use AXDescription (not AXTitle) for their label,
    and include the keyboard shortcut, e.g. "Mute (⌘ ⇧ M)".

    Returns the element if found, None otherwise.
    """
    if depth > max_depth:
        return None

    try:
        role = _get_ax_attr(element, "AXRole")
        if not role:
            return None

        if str(role) == "AXButton":
            # Teams buttons use AXDescription, not AXTitle
            desc = _get_ax_attr(element, "AXDescription")
            if desc:
                desc_lower = str(desc).lower()
                if desc_lower.startswith(_MUTED_PREFIXES + _UNMUTED_PREFIXES):
                    return element

            # Fallback: check AXTitle too (other apps)
            title = _get_ax_attr(element, "AXTitle")
            if title:
                title_lower = str(title).lower()
                if title_lower.startswith(_MUTED_PREFIXES + _UNMUTED_PREFIXES):
                    return element

        # Recurse into children
        children = _get_ax_attr(element, "AXChildren")
        if not children:
            return None

        for child in children:
            result = _find_mute_button(child, depth + 1, max_depth)
            if result is not None:
                return result

    except Exception:
        return None

    return None


def _read_mute_state(pid: int) -> bool | None:
    """Read the mute state from Teams UI for the given PID.

    Returns True if muted, False if unmuted, None if can't determine.
    """
    try:
        from ApplicationServices import AXUIElementCreateApplication

        app_element = AXUIElementCreateApplication(pid)
        if not app_element:
            return None

        button = _find_mute_button(app_element)
        if button is None:
            return None

        # Check description first (Teams), then title (fallback)
        for attr in ("AXDescription", "AXTitle"):
            text = _get_ax_attr(button, attr)
            if not text:
                continue
            text_lower = str(text).lower()
            if text_lower.startswith(_MUTED_PREFIXES):
                return True  # muted (button says "Unmute")
            if text_lower.startswith(_UNMUTED_PREFIXES):
                return False  # unmuted (button says "Mute")

        return None

    except Exception as exc:
        log.debug("Failed to read mute state: %s", exc)
        return None


class MuteTracker:
    """Polls Teams mute state and records transitions.

    Runs a daemon thread that checks mute state every ``poll_interval``
    seconds. The timeline is available via :attr:`timeline`.

    Graceful degradation: if Accessibility API is unavailable or
    permission is denied, logs a warning and records an empty timeline.
    """

    def __init__(self, teams_pid: int, poll_interval: float = 0.5):
        self.teams_pid = teams_pid
        self.poll_interval = poll_interval
        self.timeline: list[MuteTransition] = []
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._last_state: bool | None = None

    @property
    def is_active(self) -> bool:
        """Whether the polling thread is running."""
        return self._thread is not None and self._thread.is_alive()

    def start(self) -> None:
        """Start polling in a daemon thread."""
        if not _is_accessibility_trusted():
            log.warning(
                "Accessibility permission not granted — mute detection disabled. "
                "Enable: System Settings > Privacy & Security > Accessibility"
            )
            return

        self._thread = threading.Thread(target=self._poll_loop, daemon=True)
        self._thread.start()
        log.info("Mute tracker started for PID %d", self.teams_pid)

    def stop(self) -> None:
        """Stop the polling thread."""
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=2)
            self._thread = None
        log.info("Mute tracker stopped — %d transitions recorded", len(self.timeline))

    def _poll_loop(self) -> None:
        """Poll mute state until stopped."""
        while not self._stop.is_set():
            state = _read_mute_state(self.teams_pid)
            if state is not None and state != self._last_state:
                transition = MuteTransition(timestamp=time.monotonic(), is_muted=state)
                self.timeline.append(transition)
                self._last_state = state
                log.debug("Mute transition: %s", "MUTED" if state else "UNMUTED")
            self._stop.wait(self.poll_interval)
