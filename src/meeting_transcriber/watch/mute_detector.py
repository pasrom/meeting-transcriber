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


def _find_elements_by_role(element, role: str, depth: int = 0, max_depth: int = 25):
    """Recursively collect all AX elements with the given role."""
    if depth > max_depth:
        return []

    results = []
    try:
        el_role = _get_ax_attr(element, "AXRole")
        if el_role and str(el_role) == role:
            results.append(element)

        children = _get_ax_attr(element, "AXChildren")
        if children:
            for child in children:
                results.extend(
                    _find_elements_by_role(child, role, depth + 1, max_depth)
                )
    except Exception:
        pass
    return results


def _find_element_by_identifier(
    element, identifier: str, depth: int = 0, max_depth: int = 25
):
    """Find the first AX element whose AXIdentifier matches."""
    if depth > max_depth:
        return None

    try:
        eid = _get_ax_attr(element, "AXIdentifier")
        if eid and str(eid) == identifier:
            return element

        children = _get_ax_attr(element, "AXChildren")
        if children:
            for child in children:
                result = _find_element_by_identifier(
                    child, identifier, depth + 1, max_depth
                )
                if result is not None:
                    return result
    except Exception:
        pass
    return None


def _extract_text_values(element, depth: int = 0, max_depth: int = 10):
    """Collect all non-empty AXValue/AXTitle strings from AXStaticText elements."""
    if depth > max_depth:
        return []

    texts = []
    try:
        role = _get_ax_attr(element, "AXRole")
        if role and str(role) == "AXStaticText":
            for attr in ("AXValue", "AXTitle"):
                val = _get_ax_attr(element, attr)
                if val:
                    text = str(val).strip()
                    if text:
                        texts.append(text)

        children = _get_ax_attr(element, "AXChildren")
        if children:
            for child in children:
                texts.extend(_extract_text_values(child, depth + 1, max_depth))
    except Exception:
        pass
    return texts


def read_participants(pid: int) -> list[str] | None:
    """Read participant names from Teams meeting roster via AX.

    Searches the AX tree for the participant/roster panel and extracts
    display names. Tries multiple strategies since Teams' AX structure
    varies between versions and meeting states.

    Returns list of participant display names, or None if roster
    not found (e.g. not in a meeting, panel not open).
    """
    try:
        from ApplicationServices import AXUIElementCreateApplication

        app_element = AXUIElementCreateApplication(pid)
        if not app_element:
            return None

        # Strategy 1: Look for a roster/people panel by known identifiers.
        # Teams Electron uses identifiers like "roster-list", "people-pane",
        # "participant-list" etc.
        for panel_id in (
            "roster-list",
            "people-pane",
            "participant-list",
            "roster-container",
        ):
            panel = _find_element_by_identifier(app_element, panel_id)
            if panel:
                texts = _extract_text_values(panel)
                names = _filter_participant_names(texts)
                if names:
                    log.info(
                        "Found %d participants via identifier '%s'",
                        len(names),
                        panel_id,
                    )
                    return names

        # Strategy 2: Look for AXList/AXTable/AXOutline elements that
        # contain multiple AXCell/AXRow children with text — likely a
        # participant roster.
        for container_role in ("AXList", "AXTable", "AXOutline"):
            containers = _find_elements_by_role(app_element, container_role)
            for container in containers:
                children = _get_ax_attr(container, "AXChildren")
                if not children or len(children) < 2:
                    continue

                # Extract text from each row/cell
                row_texts = []
                for child in children:
                    texts = _extract_text_values(child, max_depth=5)
                    if texts:
                        row_texts.append(texts[0])  # First text is usually the name

                names = _filter_participant_names(row_texts)
                if len(names) >= 2:
                    log.info(
                        "Found %d participants via %s container",
                        len(names),
                        container_role,
                    )
                    return names

        # Strategy 3: Look for the meeting window title bar — it sometimes
        # shows "Meeting with X, Y, Z" or similar.
        windows = _find_elements_by_role(app_element, "AXWindow", max_depth=1)
        for window in windows:
            title = _get_ax_attr(window, "AXTitle")
            if not title:
                continue
            title_str = str(title)
            # Skip non-meeting windows
            if "Chat |" in title_str or "Microsoft Teams" == title_str:
                continue
            # Some meeting titles list participants
            if " | Microsoft Teams" in title_str:
                meeting_part = title_str.replace(" | Microsoft Teams", "")
                # "John, Jane, Bob" style titles
                if "," in meeting_part:
                    parts = [p.strip() for p in meeting_part.split(",")]
                    names = _filter_participant_names(parts)
                    if len(names) >= 2:
                        log.info("Found %d participants from window title", len(names))
                        return names

        log.debug("No participant roster found in AX tree")
        return None

    except Exception as exc:
        log.debug("Failed to read participants: %s", exc)
        return None


def _filter_participant_names(texts: list[str]) -> list[str]:
    """Filter a list of text strings to likely participant names.

    Removes UI labels, timestamps, status indicators, and other
    non-name strings that appear in the Teams AX tree.
    """
    # Common non-name strings in the Teams UI
    _SKIP_PATTERNS = {
        "mute",
        "unmute",
        "muted",
        "unmuted",
        "camera",
        "share",
        "chat",
        "people",
        "raise hand",
        "leave",
        "more",
        "reactions",
        "participants",
        "in this meeting",
        "invited",
        "in the lobby",
        "presenter",
        "attendee",
        "organizer",
        "guest",
        "(you)",
        "search",
        "recording",
        "transcription",
    }

    names = []
    seen = set()
    for text in texts:
        text = text.strip()
        if not text:
            continue
        lower = text.lower()
        # Skip single characters, pure numbers, timestamps
        if len(text) <= 1:
            continue
        if text.isdigit():
            continue
        if ":" in text and any(c.isdigit() for c in text):
            continue  # Likely a timestamp like "10:30"
        # Skip known UI labels
        if lower in _SKIP_PATTERNS:
            continue
        if any(lower.startswith(p) for p in _SKIP_PATTERNS):
            continue
        # Remove "(you)" suffix from own name
        if lower.endswith("(you)"):
            text = text[: text.lower().rfind("(you)")].strip()
        if text and text not in seen:
            names.append(text)
            seen.add(text)

    return names


def write_participants(names: list[str], meeting_title: str = "") -> None:
    """Write detected participant names to participants.json for the Swift app."""
    import json
    import os

    from meeting_transcriber.config import PARTICIPANTS_FILE

    data = {
        "version": 1,
        "meeting_title": meeting_title,
        "participants": names,
    }

    PARTICIPANTS_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = PARTICIPANTS_FILE.with_suffix(".tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp_path, PARTICIPANTS_FILE)
    log.info("Wrote %d participants to %s", len(names), PARTICIPANTS_FILE)


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
