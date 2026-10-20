#!/usr/bin/env python3
"""Read the appcast's minimum macOS version from a built app's Info.plist."""

import plistlib
import re
import sys
from xml.parsers.expat import ExpatError


def version_components(value, key):
    if (not isinstance(value, str) or len(value) > 64
            or re.fullmatch(r"[1-9][0-9]*\.(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*))?", value) is None):
        raise ValueError(f"{key} must be a numeric macOS version such as 15.5 or 15.5.0")
    components = tuple(int(part) for part in value.split("."))
    return components + (0,) * (3 - len(components))


def minimum_system_version(info):
    if not isinstance(info, dict):
        raise ValueError("Info.plist must contain a dictionary")
    minimum = info.get("LSMinimumSystemVersion")
    components = version_components(minimum, "LSMinimumSystemVersion")
    overrides = info.get("LSMinimumSystemVersionByArchitecture", {})
    if not isinstance(overrides, dict):
        raise ValueError("LSMinimumSystemVersionByArchitecture must contain a dictionary")
    for architecture, value in overrides.items():
        if not isinstance(architecture, str) or not architecture:
            raise ValueError("Minimum-system-version architecture names must be nonempty strings")
        if version_components(value, f"Minimum version for {architecture}") != components:
            raise ValueError("Architecture-specific minimum versions must agree with LSMinimumSystemVersion")
    return minimum


def main(arguments):
    if len(arguments) != 1:
        print("Usage: Scripts/appcast_minimum.py <archived-app-Info.plist>", file=sys.stderr)
        return 64
    try:
        with open(arguments[0], "rb") as stream:
            info = plistlib.load(stream)
        minimum = minimum_system_version(info)
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException, ExpatError) as error:
        print(f"Archived app minimum macOS version is invalid: {error}", file=sys.stderr)
        return 65
    print(minimum)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
