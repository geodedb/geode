#!/usr/bin/env python3
"""
Check for compile-time feature flags in the codebase.
Fails if any feature flags are found.
"""

import argparse
import os
import re
import sys
from pathlib import Path

# Patterns that indicate feature flags
FEATURE_FLAG_PATTERNS = [
    re.compile(r"-Dfeature_\w+"),  # Zig build flags
    re.compile(r'@import\("build_options"\)\.feature_'),  # Zig code
    re.compile(r"if\s*\(\s*comptime\s+feature_"),  # Zig comptime checks
    re.compile(r"const\s+feature_\w+\s*="),  # Feature flag definitions
]

# Files/directories to skip
SKIP_PATTERNS = {
    "/.git/",
    "/zig-cache/",
    "/zig-out/",
    "/vendor/",
    "/.zig-cache/",
    "/node_modules/",
    "/kb/reviews/",  # Skip review documentation
    "/docs/",  # Skip documentation
    "/docker/zig-packages/",  # Skip vendored Zig dependency cache (legacy path)
    "/zig-pkg/",  # Skip vendored Zig dependency cache (current path)
    "/.worktrees/",  # Skip git worktrees (gitignored)
    "/.claude/worktrees/",  # Skip Claude agent worktrees (gitignored)
}


def check_file_for_feature_flags(file_path: Path) -> list[tuple[int, str]]:
    """Check a single file for feature flags."""
    violations = []

    try:
        with open(file_path, encoding="utf-8") as f:
            for line_num, line in enumerate(f, 1):
                for pattern in FEATURE_FLAG_PATTERNS:
                    if pattern.search(line):
                        violations.append((line_num, line.strip()))
                        break
    except (UnicodeDecodeError, PermissionError):
        # Skip binary files or files we can't read
        pass

    return violations


def check_repository(repo_path: Path) -> list[tuple[Path, list[tuple[int, str]]]]:
    """Check entire repository for feature flags."""
    all_violations = []

    # File extensions to check
    check_extensions = {".zig", ".py", ".sh", ".yaml", ".yml"}
    # Note: .md files excluded to avoid false positives in documentation

    for root, dirs, files in os.walk(repo_path):
        # Skip certain directories
        root_str = str(root)
        if any(skip in root_str for skip in SKIP_PATTERNS):
            continue

        # Modify dirs in-place to skip hidden directories
        dirs[:] = [d for d in dirs if not d.startswith(".")]

        for file in files:
            file_path = Path(root) / file

            # Only check relevant file types
            if file_path.suffix not in check_extensions and file != "build.zig":
                continue

            violations = check_file_for_feature_flags(file_path)
            if violations:
                rel_path = file_path.relative_to(repo_path)
                all_violations.append((rel_path, violations))

    return all_violations


def main():
    parser = argparse.ArgumentParser(description="Check for compile-time feature flags")
    parser.add_argument("--repo", type=Path, default=Path("."), help="Repository root path")

    args = parser.parse_args()

    # Check for feature flags
    violations = check_repository(args.repo)

    if violations:
        # Found feature flags - report and fail
        print("FEATURE_FLAG_FOUND", file=sys.stderr)
        print("\nFeature flags detected in the following files:", file=sys.stderr)

        for file_path, file_violations in violations:
            print(f"\n  {file_path}:", file=sys.stderr)
            for line_num, line_content in file_violations:
                print(f"    Line {line_num}: {line_content[:80]}...", file=sys.stderr)

        print(f"\nTotal files with feature flags: {len(violations)}", file=sys.stderr)
        return 2
    else:
        # No feature flags found - success
        print("NO_FEATURE_FLAGS_OK")
        return 0


if __name__ == "__main__":
    sys.exit(main())
