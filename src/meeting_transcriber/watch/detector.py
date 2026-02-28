"""Meeting detection via CGWindowListCopyWindowInfo polling."""

import logging
import re
import time
from dataclasses import dataclass, field

from rich.console import Console

from meeting_transcriber.watch.patterns import AppMeetingPattern

console = Console()
log = logging.getLogger(__name__)


@dataclass
class DetectedMeeting:
    """Represents a detected active meeting."""

    pattern: AppMeetingPattern
    window_title: str
    owner_name: str
    window_pid: int
    detected_at: float = field(default_factory=time.time)


class MeetingDetector:
    """Polls CGWindowListCopyWindowInfo to detect active meeting windows."""

    def __init__(
        self,
        patterns: list[AppMeetingPattern],
        confirmation_count: int = 2,
    ):
        self.patterns = patterns
        self.confirmation_count = confirmation_count
        self._consecutive_hits: dict[str, int] = {}  # pattern.app_name -> count
        self._permission_warned = False

    def _get_windows(self) -> list[dict]:
        """Fetch on-screen window list via Quartz."""
        from Quartz import (
            CGWindowListCopyWindowInfo,
            kCGNullWindowID,
            kCGWindowListOptionOnScreenOnly,
        )

        windows = CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly, kCGNullWindowID
        )
        result = list(windows) if windows else []

        # Check if window names are missing (Screen Recording permission issue)
        if result and not self._permission_warned:
            has_names = any(w.get("kCGWindowName") for w in result)
            if not has_names:
                console.print(
                    "[red]Cannot read window titles — Screen Recording"
                    " permission required for this app.[/red]\n"
                    "[dim]System Settings → Privacy & Security → Screen Recording"
                    " → enable for MeetingTranscriber[/dim]"
                )
                self._permission_warned = True

        return result

    def _match_window(self, window: dict, pattern: AppMeetingPattern) -> str | None:
        """Check if a window matches a meeting pattern. Returns title or None."""
        owner = window.get("kCGWindowOwnerName", "")
        if owner not in pattern.owner_names:
            return None

        title = window.get("kCGWindowName", "")
        if not title:
            return None

        # Check minimum size
        bounds = window.get("kCGWindowBounds", {})
        width = bounds.get("Width", 0)
        height = bounds.get("Height", 0)
        if width < pattern.min_window_width or height < pattern.min_window_height:
            return None

        # Skip idle patterns
        for idle_re in pattern.idle_patterns:
            if re.match(idle_re, title):
                return None

        # Match meeting patterns
        for meeting_re in pattern.meeting_patterns:
            if re.match(meeting_re, title):
                return title

        return None

    def check_once(self) -> DetectedMeeting | None:
        """Single poll: check all windows against all patterns.

        Returns a DetectedMeeting only after confirmation_count consecutive
        positive detections for the same app.
        """
        windows = self._get_windows()

        # Track which apps had a hit this round
        hits_this_round: set[str] = set()

        for window in windows:
            for pattern in self.patterns:
                title = self._match_window(window, pattern)
                if title is not None:
                    hits_this_round.add(pattern.app_name)
                    self._consecutive_hits.setdefault(pattern.app_name, 0)
                    self._consecutive_hits[pattern.app_name] += 1

                    if (
                        self._consecutive_hits[pattern.app_name]
                        >= self.confirmation_count
                    ):
                        pid = window.get("kCGWindowOwnerPID", 0)
                        return DetectedMeeting(
                            pattern=pattern,
                            window_title=title,
                            owner_name=window.get("kCGWindowOwnerName", ""),
                            window_pid=pid,
                        )

        # Reset counters for apps that had no hit this round
        for app_name in list(self._consecutive_hits.keys()):
            if app_name not in hits_this_round:
                self._consecutive_hits[app_name] = 0

        return None

    def is_meeting_active(self, meeting: DetectedMeeting) -> bool:
        """Check if a previously detected meeting is still active."""
        windows = self._get_windows()
        for window in windows:
            title = self._match_window(window, meeting.pattern)
            if title is not None:
                return True
        return False

    def reset(self) -> None:
        """Reset all confirmation counters."""
        self._consecutive_hits.clear()
