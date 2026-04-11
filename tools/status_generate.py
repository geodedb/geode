#!/usr/bin/env python3
"""
Generate status.csv from CANARY markers in the codebase.
"""

import argparse
import csv
import os
import re
from pathlib import Path

# CANARY pattern: CANARY: REQ=REQ-XXX; FEATURE="..."; ASPECT=...; STATUS=...; [TEST=...;]* [BENCH=...;]* OWNER=...; UPDATED=...
# Allows multiple TEST= and BENCH= fields (common in test files)
# Handles both FEATURE="..." and FEATURE=\"...\" (escaped quotes in shell/string literals)
CANARY_PATTERN = re.compile(
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


def find_canary_markers(repo_path: Path) -> list[dict[str, str]]:
    """Find all CANARY markers in the repository."""
    markers = []

    # File extensions to search
    extensions = {".zig", ".py", ".md", ".sh", ".yaml", ".yml"}

    for root, _, files in os.walk(repo_path):
        # Skip hidden directories, vendor directories, and worktrees
        if (
            "/.git" in root
            or "/vendor" in root
            or "/zig-cache" in root
            or "/zig-packages" in root
            or "/.worktrees" in root
            or "/.claude/worktrees" in root
            or "/zig-out" in root
            or "/docs/superpowers/plans" in root
        ):
            continue

        for file in files:
            file_path = Path(root) / file

            # Only process files with relevant extensions
            if file_path.suffix not in extensions:
                continue

            try:
                with open(file_path, encoding="utf-8") as f:
                    content = f.read()

                for match in CANARY_PATTERN.finditer(content):
                    marker = match.groupdict()
                    marker["file"] = str(file_path.relative_to(repo_path))
                    markers.append(marker)

            except (UnicodeDecodeError, PermissionError):
                # Skip binary files or files we can't read
                continue

    return markers


def generate_status_csv(markers: list[dict[str, str]], output_path: Path) -> int:
    """Generate status.csv from CANARY markers."""

    # Sort by REQ ID, then by feature, then by aspect, then by file for deterministic output
    # Including file in sort key ensures consistent ordering across different environments
    markers.sort(key=lambda m: (m["req"], m["feature"], m["aspect"], m["file"]))

    # Write CSV
    with open(output_path, "w", newline="") as csvfile:
        fieldnames = ["REQ", "Feature", "Aspect", "Status", "Test", "Bench", "Owner", "Updated", "File"]
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)

        writer.writeheader()
        for marker in markers:
            writer.writerow(
                {
                    "REQ": marker["req"],
                    "Feature": marker["feature"],
                    "Aspect": marker["aspect"],
                    "Status": marker["status"],
                    "Test": marker.get("test", ""),
                    "Bench": marker.get("bench", ""),
                    "Owner": marker["owner"],
                    "Updated": marker["updated"],
                    "File": marker["file"],
                }
            )

    return len(markers)


def main():
    parser = argparse.ArgumentParser(description="Generate status.csv from CANARY markers")
    parser.add_argument("--repo", type=Path, default=Path("."), help="Repository root path")
    parser.add_argument("--out", type=Path, default=Path("docs/status.csv"), help="Output CSV file path")

    args = parser.parse_args()

    # Find all CANARY markers
    markers = find_canary_markers(args.repo)

    # Generate status.csv
    count = generate_status_csv(markers, args.out)

    # Print success message
    print(f"STATUS_CSV_WRITTEN path={args.out} items={count}")

    return 0


if __name__ == "__main__":
    exit(main())
