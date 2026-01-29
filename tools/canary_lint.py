#!/usr/bin/env python3
"""
Lint CANARY markers to ensure they conform to the required schema.

This script is intended to be run in CI to catch malformed CANARY markers.
It will exit with code 2 if any malformed markers are found.

Required CANARY format:
CANARY: REQ=REQ-XXX; FEATURE="..."; ASPECT=...; STATUS=...; [TEST=...;] [BENCH=...;] OWNER=...; UPDATED=...

Valid STATUS values: STUB, IMPL, TESTED, BENCHED, COMPLETE, EXEMPT
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Dict, List

# Valid status values per AGENTS.md
VALID_STATUSES = {"STUB", "IMPL", "TESTED", "BENCHED", "COMPLETE", "EXEMPT"}

# Pattern for complete, conforming CANARY marker
# Allows multiple TEST= and BENCH= fields (common in test files)
# Handles both FEATURE="..." and FEATURE=\"...\" (escaped quotes in shell/string literals)
CANARY_COMPLETE_PATTERN = re.compile(
    r"CANARY:\s*"
    r"REQ=(?P<req>[^;]+);\s*"
    r'FEATURE=\\?"(?P<feature>[^"\\]+(?:\\.[^"\\]*)*)\\?";\s*'  # Handle escaped or unescaped quotes
    r"ASPECT=(?P<aspect>[^;]+);\s*"
    r"STATUS=(?P<status>[^;]+);\s*"
    r"(?:TEST=[^;]+;\s*)*"  # Zero or more TEST= fields
    r"(?:BENCH=[^;]+;\s*)*"  # Zero or more BENCH= fields
    r"OWNER=(?P<owner>[^;]+);\s*"
    r"UPDATED=(?P<updated>[^;\s]+)"
)

# Pattern for CANARY markers that appear to be formal (have FEATURE=)
# Informal markers like "CANARY: REQ=REQ-XXX; some comment" are allowed
# Handles both FEATURE="..." and FEATURE=\"...\" (escaped quotes)
CANARY_LOOSE_PATTERN = re.compile(r'CANARY:\s*REQ=[^;]+;\s*FEATURE=\\?"')

# Pattern to identify documentation/example markers (not real markers)
# These use "..." or placeholders like REQ-XXX or REQ-GQL-###
CANARY_EXAMPLE_PATTERN = re.compile(
    r'CANARY:\s*REQ=REQ-(?:XXX|GQL-###|GQL-XXX);.*FEATURE="(?:\.{3}|Name)"'
    r"|CANARY pattern:"  # Lines documenting the CANARY pattern
    r"|f\'.* CANARY:"  # Python f-string templates generating markers
    r'|FEATURE="[^"]*\{[^}]+\}"'  # Python f-string templates with {variable}
    r'|^\s*line\s*=\s*[\'"]'  # Python test string assignments (line = '...')
)


def lint_file(filepath: Path) -> List[Dict]:
    """
    Lint a single file for CANARY marker issues.

    Returns list of issue dictionaries.
    """
    issues = []

    try:
        with open(filepath, encoding="utf-8") as f:
            lines = f.readlines()
    except (UnicodeDecodeError, PermissionError):
        return []

    for i, line in enumerate(lines, 1):
        if CANARY_LOOSE_PATTERN.search(line):
            # Skip documentation examples (template patterns, not real markers)
            if CANARY_EXAMPLE_PATTERN.search(line):
                continue

            # Found a CANARY marker, check if it's complete
            match = CANARY_COMPLETE_PATTERN.search(line)

            if not match:
                # Malformed marker
                issues.append(
                    {
                        "file": str(filepath),
                        "line": i,
                        "type": "malformed",
                        "message": "CANARY marker missing required fields (ASPECT, OWNER, or UPDATED)",
                        "content": line.strip()[:100],
                    }
                )
            else:
                # Check status validity
                status = match.group("status")
                if status not in VALID_STATUSES:
                    issues.append(
                        {
                            "file": str(filepath),
                            "line": i,
                            "type": "invalid_status",
                            "message": f"Invalid STATUS='{status}' (valid: {', '.join(sorted(VALID_STATUSES))})",
                            "content": line.strip()[:100],
                        }
                    )

    return issues


def main():
    parser = argparse.ArgumentParser(description="Lint CANARY markers for schema compliance")
    parser.add_argument("--repo", type=Path, default=Path("."), help="Repository root path")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    parser.add_argument("--fail-on-issues", action="store_true", help="Exit with code 2 if issues found")

    args = parser.parse_args()

    # File extensions to search
    extensions = {".zig", ".py", ".md", ".sh", ".yaml", ".yml"}

    all_issues = []

    for root, _, files in os.walk(args.repo):
        # Skip hidden directories and vendor directories
        if "/.git" in root or "/vendor" in root or "/zig-cache" in root or "/zig-out" in root:
            continue

        for file in files:
            filepath = Path(root) / file

            if filepath.suffix not in extensions:
                continue

            issues = lint_file(filepath)
            if issues:
                # Convert paths to relative
                for issue in issues:
                    try:
                        issue["file"] = str(Path(issue["file"]).relative_to(args.repo))
                    except ValueError:
                        pass
                all_issues.extend(issues)

    # Count by type
    malformed_count = sum(1 for i in all_issues if i["type"] == "malformed")
    invalid_status_count = sum(1 for i in all_issues if i["type"] == "invalid_status")

    if args.json:
        result = {
            "total_issues": len(all_issues),
            "malformed": malformed_count,
            "invalid_status": invalid_status_count,
            "issues": all_issues,
            "ok": len(all_issues) == 0,
        }
        print(json.dumps(result, indent=2))
    else:
        if all_issues:
            print(f"CANARY Lint: Found {len(all_issues)} issues")
            print(f"  - Malformed markers: {malformed_count}")
            print(f"  - Invalid status values: {invalid_status_count}")
            print()
            for issue in all_issues:
                print(f"{issue['file']}:{issue['line']}: {issue['message']}")
                print(f"  {issue['content']}")
                print()
        else:
            print("CANARY Lint: OK - All markers conform to schema")

    if args.fail_on_issues and all_issues:
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())
