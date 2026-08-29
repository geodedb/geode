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
#
# GAP-0539 (2026-04-16): each field capture explicitly excludes newlines
# (`[^;\n]+`) so that the regex cannot straddle a Zig test declaration
# like `test "CANARY: REQ=REQ-X"` followed on the next line by the real
# marker comment.  Before this fix, 16 rows in status.csv had blank
# STATUS columns because req captured `REQ-GQL-...\n//...`.
CANARY_PATTERN = re.compile(
    r"CANARY:[ \t]*"
    r"REQ=(?P<req>[^;\n]+);[ \t]*"
    r'FEATURE=\\?"(?P<feature>[^"\\\n]+(?:\\.[^"\\\n]*)*)\\?";[ \t]*'  # same-line feature
    r"ASPECT=(?P<aspect>[^;\n]+);[ \t]*"
    r"STATUS=(?P<status>[^;\n]+);[ \t]*"
    r"(?:TEST=[^;\n]+;[ \t]*)*"  # Zero or more TEST= fields
    r"(?:BENCH=[^;\n]+;[ \t]*)*"  # Zero or more BENCH= fields
    r"OWNER=(?P<owner>[^;\n]+);[ \t]*"
    r"UPDATED=(?P<updated>[^;\s]+)"
)

# GAP-0539: STATUS values must come from the CANARY schema.  Anything else
# (e.g. ad-hoc "COMPLETE" or parser garbage) is dropped with a warning — the
# underlying marker should be fixed in its source file.
VALID_STATUS = frozenset({"TESTED", "IMPL", "EXEMPT", "BENCHED", "STUB", "PENDING"})


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
            or "/zig-pkg" in root
            or "/.worktrees" in root
            or "/.claude/worktrees" in root
            or "/zig-out" in root
            or "/docs/superpowers/plans" in root
            # Whole-branch review Finding 3: `.superpowers/` (gitignored —
            # see .gitignore) holds per-session scratch state, including
            # task briefs (`.superpowers/sdd/task-*-brief.md`) that
            # sometimes carry CANARY markers copy-pasted from source for
            # planning purposes. Those aren't real requirement evidence —
            # the file isn't tracked, doesn't ship, and a fresh clone or
            # CI run without that local session state produces a DIFFERENT
            # status.csv than a machine with an active session, so
            # status.csv stopped being reproducible from tracked source.
            or "/.superpowers" in root
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


def generate_status_csv(markers: list[dict[str, str]], output_path: Path, strict: bool = True) -> int:
    """Generate status.csv from CANARY markers.

    When ``strict`` is True (the default), markers whose STATUS is not one of
    ``VALID_STATUS`` are dropped with a warning printed to stderr.  This is
    the GAP-0539 fix for schema-invalid rows like ``STATUS=COMPLETE``.
    """
    import sys

    # GAP-0539: drop schema-invalid STATUS values rather than silently
    # pollute the CSV (or the downstream CI check that trusts the CSV as
    # ground truth).
    clean: list[dict[str, str]] = []
    rejected = 0
    for marker in markers:
        status = marker.get("status", "").strip()
        if strict and status not in VALID_STATUS:
            print(
                f"STATUS_GEN_WARN file={marker.get('file', '?')} req={marker.get('req', '?')} "
                f"bad_status={status!r} — dropped (not in VALID_STATUS={sorted(VALID_STATUS)})",
                file=sys.stderr,
            )
            rejected += 1
            continue
        clean.append(marker)

    if rejected:
        print(
            f"STATUS_GEN_SUMMARY accepted={len(clean)} rejected={rejected}",
            file=sys.stderr,
        )

    # Sort by REQ ID, then by feature, then by aspect, then by file for deterministic output
    # Including file in sort key ensures consistent ordering across different environments
    clean.sort(key=lambda m: (m["req"], m["feature"], m["aspect"], m["file"]))

    # Write CSV
    with open(output_path, "w", newline="") as csvfile:
        fieldnames = ["REQ", "Feature", "Aspect", "Status", "Test", "Bench", "Owner", "Updated", "File"]
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)

        writer.writeheader()
        for marker in clean:
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

    return len(clean)


def main():
    parser = argparse.ArgumentParser(description="Generate status.csv from CANARY markers")
    parser.add_argument("--repo", type=Path, default=Path("."), help="Repository root path")
    parser.add_argument("--out", type=Path, default=Path("docs/status.csv"), help="Output CSV file path")
    parser.add_argument(
        "--allow-invalid-status",
        action="store_true",
        help="Do not drop rows with non-schema STATUS values (debug only; GAP-0539)",
    )

    args = parser.parse_args()

    # Find all CANARY markers
    markers = find_canary_markers(args.repo)

    # Generate status.csv (strict-by-default per GAP-0539)
    count = generate_status_csv(markers, args.out, strict=not args.allow_invalid_status)

    # Print success message
    print(f"STATUS_CSV_WRITTEN path={args.out} items={count}")

    return 0


if __name__ == "__main__":
    exit(main())
