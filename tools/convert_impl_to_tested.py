#!/usr/bin/env python3
"""
GAP-0209 Fix: Convert CANARY markers with STATUS=IMPL and TEST= to STATUS=TESTED.

This script finds all CANARY markers that have both:
1. STATUS=IMPL (indicating implementation is done)
2. TEST= field (indicating test exists)

And converts STATUS=IMPL to STATUS=TESTED since test evidence is already present.
"""

import os
import re
from pathlib import Path

# Pattern to match CANARY markers with IMPL status AND a TEST field
IMPL_WITH_TEST_PATTERN = re.compile(
    r'(CANARY:.*?)STATUS=IMPL(.*?TEST=[^;]+)'
)

def process_file(file_path: Path) -> tuple[int, list[str]]:
    """Process a single file and convert IMPL to TESTED where TEST exists."""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
    except (UnicodeDecodeError, PermissionError):
        return 0, []

    # Find all matches
    matches = list(IMPL_WITH_TEST_PATTERN.finditer(content))
    if not matches:
        return 0, []

    # Perform replacements
    new_content = IMPL_WITH_TEST_PATTERN.sub(r'\1STATUS=TESTED\2', content)

    if new_content != content:
        with open(file_path, 'w', encoding='utf-8') as f:
            f.write(new_content)

        changes = []
        for match in matches:
            changes.append(f"  Line containing: {match.group(0)[:80]}...")

        return len(matches), changes

    return 0, []

def main():
    repo_root = Path('/home/benji/src/gl/devnw/codepros/geode')
    src_path = repo_root / 'src'

    # Extensions to process
    extensions = {'.zig', '.py'}

    total_converted = 0
    files_modified = 0

    print("GAP-0209 Fix: Converting IMPL to TESTED for markers with TEST references")
    print("=" * 70)

    for root, _, files in os.walk(src_path):
        # Skip hidden and vendor directories
        if '/.git' in root or '/vendor' in root or '/zig-cache' in root:
            continue

        for file in files:
            file_path = Path(root) / file

            if file_path.suffix not in extensions:
                continue

            count, changes = process_file(file_path)
            if count > 0:
                files_modified += 1
                total_converted += count
                rel_path = file_path.relative_to(repo_root)
                print(f"\n{rel_path}: {count} marker(s) converted")
                for change in changes[:3]:  # Show first 3 changes per file
                    print(change)
                if len(changes) > 3:
                    print(f"  ... and {len(changes) - 3} more")

    print("\n" + "=" * 70)
    print(f"Summary: {total_converted} markers converted in {files_modified} files")
    print("Run 'make status-generate' to regenerate status.csv")

    return 0

if __name__ == '__main__':
    exit(main())
