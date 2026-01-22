#!/usr/bin/env python3
"""
GAP-0209 Fix: Convert TransactionUndoLog IMPL markers to TESTED.

These markers are tested by:
- geodetestlab/specs/transaction_state_basic.yml
- geodetestlab/specs/gql_transaction_management_comprehensive.yml
"""

import os
import re
from pathlib import Path

# Pattern to match TransactionUndoLog IMPL markers
TXN_UNDO_IMPL_PATTERN = re.compile(
    r'(CANARY:.*?FEATURE="TransactionUndoLog".*?)STATUS=IMPL(.*?)(?=;|\n|$)'
)

def process_file(file_path: Path) -> tuple[int, list[str]]:
    """Process a single file and convert TransactionUndoLog IMPL to TESTED."""
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
    except (UnicodeDecodeError, PermissionError):
        return 0, []

    matches = list(TXN_UNDO_IMPL_PATTERN.finditer(content))
    if not matches:
        return 0, []

    def replace_func(match):
        prefix = match.group(1)
        suffix = match.group(2) if match.group(2) else ""
        if "TEST=" in prefix + suffix:
            return match.group(0)
        return f'{prefix}STATUS=TESTED; TEST=geodetestlab/specs/transaction_state_basic.yml{suffix}'

    new_content = TXN_UNDO_IMPL_PATTERN.sub(replace_func, content)

    if new_content != content:
        with open(file_path, 'w', encoding='utf-8') as f:
            f.write(new_content)

        changes = []
        for match in matches:
            changes.append(f"  Updated: {match.group(0)[:80]}...")

        return len(matches), changes

    return 0, []

def main():
    repo_root = Path('/home/benji/src/gl/devnw/codepros/geode')
    src_path = repo_root / 'src'
    extensions = {'.zig'}
    total_converted = 0
    files_modified = 0

    print("GAP-0209 Fix: Converting TransactionUndoLog IMPL to TESTED")
    print("Test reference: geodetestlab/specs/transaction_state_basic.yml")
    print("=" * 70)

    for root, _, files in os.walk(src_path):
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
                for change in changes[:3]:
                    print(change)
                if len(changes) > 3:
                    print(f"  ... and {len(changes) - 3} more")

    print("\n" + "=" * 70)
    print(f"Summary: {total_converted} markers converted in {files_modified} files")

    return 0

if __name__ == '__main__':
    exit(main())
