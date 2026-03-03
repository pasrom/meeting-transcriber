#!/usr/bin/env python3
"""Dump the macOS Accessibility tree for Microsoft Teams.

Run this script during an active Teams meeting to discover
where participant names, roster panels, and meeting controls
appear in the AX hierarchy.

Usage:
    python scripts/dump_teams_ax.py
    python scripts/dump_teams_ax.py --depth 15
    python scripts/dump_teams_ax.py --all  # include every element

Requires:
    pip install pyobjc-framework-ApplicationServices
    Accessibility permission for the running terminal.
"""

import argparse
import subprocess
import sys


def _get_ax_attr(element, attr):
    """Read a single AX attribute. Returns value or None."""
    from ApplicationServices import (
        AXUIElementCopyAttributeValue,
        kAXErrorSuccess,
    )

    err, val = AXUIElementCopyAttributeValue(element, attr, None)
    return val if err == kAXErrorSuccess else None


# Roles that usually carry useful text or structure.
_INTERESTING_ROLES = {
    "AXStaticText",
    "AXButton",
    "AXCell",
    "AXRow",
    "AXList",
    "AXTable",
    "AXOutline",
    "AXGroup",
    "AXToolbar",
    "AXTabGroup",
    "AXHeading",
    "AXLink",
    "AXImage",
    "AXMenuItem",
    "AXMenu",
    "AXTextField",
    "AXTextArea",
    "AXWindow",
    "AXWebArea",
    "AXScrollArea",
}


def _dump_element(element, depth: int, max_depth: int, show_all: bool) -> None:
    """Recursively print the AX tree."""
    if depth > max_depth:
        return

    role = _get_ax_attr(element, "AXRole")
    if not role:
        return
    role_str = str(role)

    # Gather text attributes
    title = _get_ax_attr(element, "AXTitle")
    value = _get_ax_attr(element, "AXValue")
    desc = _get_ax_attr(element, "AXDescription")
    role_desc = _get_ax_attr(element, "AXRoleDescription")
    identifier = _get_ax_attr(element, "AXIdentifier")

    has_text = any(x for x in (title, value, desc))
    is_interesting = role_str in _INTERESTING_ROLES

    if show_all or is_interesting or has_text:
        indent = "  " * depth
        parts = [f"{indent}[{role_str}]"]
        if title:
            parts.append(f'title="{title}"')
        if value:
            val_str = str(value)
            if len(val_str) > 120:
                val_str = val_str[:120] + "..."
            parts.append(f'value="{val_str}"')
        if desc:
            parts.append(f'desc="{desc}"')
        if role_desc and role_desc != role_str:
            parts.append(f'roleDesc="{role_desc}"')
        if identifier:
            parts.append(f'id="{identifier}"')
        print(" ".join(parts))

    # Recurse into children
    children = _get_ax_attr(element, "AXChildren")
    if children:
        for child in children:
            _dump_element(child, depth + 1, max_depth, show_all)


def _find_teams_pid() -> int | None:
    """Find the PID of Microsoft Teams via pgrep."""
    try:
        result = subprocess.run(
            ["pgrep", "-x", "MSTeams"],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            pids = result.stdout.strip().split("\n")
            return int(pids[0])
    except (subprocess.SubprocessError, ValueError):
        pass

    # Fallback: try "Microsoft Teams" (older versions)
    try:
        result = subprocess.run(
            ["pgrep", "-f", "Microsoft Teams"],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            pids = result.stdout.strip().split("\n")
            return int(pids[0])
    except (subprocess.SubprocessError, ValueError):
        pass

    return None


def main():
    parser = argparse.ArgumentParser(description="Dump Teams AX tree")
    parser.add_argument(
        "--depth",
        type=int,
        default=30,
        help="Max tree depth (default: 30)",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Show all elements, not just interesting ones",
    )
    parser.add_argument(
        "--pid",
        type=int,
        default=None,
        help="Teams PID (auto-detected if omitted)",
    )
    args = parser.parse_args()

    # Check accessibility permission
    try:
        from ApplicationServices import AXIsProcessTrusted

        if not AXIsProcessTrusted():
            print(
                "ERROR: Accessibility permission not granted.\n"
                "Enable: System Settings > Privacy & Security > Accessibility",
                file=sys.stderr,
            )
            sys.exit(1)
    except ImportError:
        print(
            "ERROR: pyobjc-framework-ApplicationServices not installed.\n"
            "Run: pip install pyobjc-framework-ApplicationServices",
            file=sys.stderr,
        )
        sys.exit(1)

    pid = args.pid or _find_teams_pid()
    if not pid:
        print("ERROR: Microsoft Teams not running.", file=sys.stderr)
        sys.exit(1)

    print(f"Teams PID: {pid}")
    print(f"Max depth: {args.depth}")
    filter_desc = "all elements" if args.all else "interesting roles + text"
    print(f"Filter: {filter_desc}")
    print("=" * 72)

    from ApplicationServices import AXUIElementCreateApplication

    app_element = AXUIElementCreateApplication(pid)
    if not app_element:
        print("ERROR: Could not create AX element for Teams.", file=sys.stderr)
        sys.exit(1)

    _dump_element(app_element, depth=0, max_depth=args.depth, show_all=args.all)


if __name__ == "__main__":
    main()
