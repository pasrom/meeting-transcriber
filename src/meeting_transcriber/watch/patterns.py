"""App-specific window patterns for meeting detection."""

from dataclasses import dataclass, field


@dataclass
class AppMeetingPattern:
    """Pattern definition for detecting active meetings via window titles.

    Attributes:
        app_name: Human-readable app name (e.g. "Microsoft Teams").
        owner_names: kCGWindowOwnerName values to match.
        meeting_patterns: Regexes that indicate an active meeting window.
        idle_patterns: Regexes that indicate a non-meeting window (skipped).
        min_window_width: Minimum window width to consider (filters tiny overlays).
        min_window_height: Minimum window height to consider.
    """

    app_name: str
    owner_names: list[str]
    meeting_patterns: list[str]
    idle_patterns: list[str] = field(default_factory=list)
    min_window_width: float = 200
    min_window_height: float = 200


TEAMS_PATTERN = AppMeetingPattern(
    app_name="Microsoft Teams",
    owner_names=["Microsoft Teams", "Microsoft Teams (work or school)"],
    meeting_patterns=[
        # "Sprint Review | Microsoft Teams" or similar meeting titles
        r".+\s+\|\s+Microsoft Teams",
    ],
    idle_patterns=[
        r"^Microsoft Teams$",
        r"^Microsoft Teams \(work or school\)$",
        r"^Chat \|",
        r"^Activity \|",
        r"^Calendar \|",
        r"^Teams \|",
        r"^Files \|",
        r"^Assignments \|",
    ],
)

ZOOM_PATTERN = AppMeetingPattern(
    app_name="Zoom",
    owner_names=["zoom.us"],
    meeting_patterns=[
        r"^Zoom Meeting$",
        r"^Zoom Webinar$",
        # "Meeting Topic - Zoom" pattern
        r".+\s*-\s*Zoom$",
    ],
    idle_patterns=[
        r"^Zoom$",
        r"^Zoom Workplace$",
        r"^Home$",
    ],
)

WEBEX_PATTERN = AppMeetingPattern(
    app_name="Webex",
    owner_names=["Webex", "Cisco Webex Meetings"],
    meeting_patterns=[
        r".+\s*-\s*Webex$",
        r"^Meeting \|",
        # Active meeting window
        r".+'s Personal Room",
    ],
    idle_patterns=[
        r"^Webex$",
        r"^Cisco Webex Meetings$",
    ],
)

ALL_PATTERNS = [TEAMS_PATTERN, ZOOM_PATTERN, WEBEX_PATTERN]

PATTERN_BY_NAME: dict[str, AppMeetingPattern] = {
    p.app_name.lower(): p for p in ALL_PATTERNS
}
