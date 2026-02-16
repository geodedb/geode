#!/usr/bin/env python3
"""Guard against ad-hoc stdio handle construction in CLI modules.

This enforces use of src/utils/stdio.zig wrappers so Windows/POSIX handle logic
stays centralized.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys
from collections.abc import Iterable

DEFAULT_GLOBS = [
    "src/cli/*.zig",
]

ALLOWLIST = {
    "src/cli/lsp/transport.zig",  # Uses language-server stdio protocol specifics.
}

PATTERNS = [
    (
        re.compile(r"std\\.fs\\.File\\s*\\{\\s*\\.handle\\s*=\\s*std\\.posix\\.STD(?:IN|OUT|ERR)_FILENO"),
        "Direct POSIX stdio file-handle construction",
    ),
    (
        re.compile(r"std\\.fs\\.File\\s*\\{\\s*\\.handle\\s*=\\s*(?:std\\.os\\.windows\\.)?GetStdHandle"),
        "Direct Windows stdio file-handle construction",
    ),
]


def iter_files(repo_root: pathlib.Path, globs: Iterable[str]) -> Iterable[pathlib.Path]:
    seen: set[pathlib.Path] = set()
    for pattern in globs:
        for path in sorted(repo_root.glob(pattern)):
            if path.is_file() and path not in seen:
                seen.add(path)
                yield path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=".", help="Repository root")
    parser.add_argument(
        "--glob",
        dest="globs",
        action="append",
        help="Glob to scan (repeatable). Defaults to src/cli/*.zig",
    )
    args = parser.parse_args()

    repo_root = pathlib.Path(args.repo).resolve()
    globs = args.globs or DEFAULT_GLOBS

    violations: list[str] = []

    for path in iter_files(repo_root, globs):
        rel = path.relative_to(repo_root).as_posix()
        if rel in ALLOWLIST:
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        lines = text.splitlines()
        for lineno, line in enumerate(lines, start=1):
            for pattern, message in PATTERNS:
                if pattern.search(line):
                    violations.append(f"{rel}:{lineno}: {message}")

    if violations:
        print("stdio abstraction guard failed:", file=sys.stderr)
        for violation in violations:
            print(f"  - {violation}", file=sys.stderr)
        print(
            "Use src/utils/stdio.zig helpers (getStdin/getStdout/getStderr) instead of inline handle construction.",
            file=sys.stderr,
        )
        return 1

    print("stdio abstraction guard passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
