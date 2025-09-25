#!/usr/bin/env python3
"""Check for compile-time feature flags in the codebase."""

import sys
import pathlib
import re
from typing import List, Tuple

PATTERNS = [
    (r'-Dfeature_', 'Feature flag option found'),
    (r'if\s*\(\s*feature_', 'Feature flag conditional found'),
    (r'feature_[a-z_]+', 'Feature flag reference found'),
    (r'\.option\(bool,\s*"feature-', 'Feature flag build option found'),
]

EXCLUDE_PATHS = {
    'tools/no_feature_flags_check.py',
    '.git',
    'zig-cache',
    'zig-out',
}

def check_file(path: pathlib.Path) -> List[Tuple[int, str, str]]:
    """Check a single file for feature flags."""
    violations = []
    try:
        content = path.read_text()
        for line_num, line in enumerate(content.splitlines(), 1):
            for pattern, desc in PATTERNS:
                if re.search(pattern, line):
                    violations.append((line_num, desc, line.strip()))
    except Exception:
        pass
    return violations

def main():
    """Main entry point."""
    if len(sys.argv) != 3 or sys.argv[1] != '--repo':
        print("Usage: no_feature_flags_check.py --repo <path>", file=sys.stderr)
        sys.exit(1)
    
    repo_path = pathlib.Path(sys.argv[2])
    if not repo_path.exists():
        print(f"Error: {repo_path} does not exist", file=sys.stderr)
        sys.exit(1)
    
    found_violations = False
    
    for path in repo_path.rglob('*'):
        if path.is_file() and not any(exc in str(path) for exc in EXCLUDE_PATHS):
            if path.suffix in {'.zig', '.py', '.sh', '.md'}:
                violations = check_file(path)
                if violations:
                    found_violations = True
                    for line_num, desc, line in violations:
                        print(f"FEATURE_FLAG_FOUND {path}:{line_num} {desc}: {line}", file=sys.stderr)
    
    if found_violations:
        sys.exit(2)
    else:
        print("NO_FEATURE_FLAGS_OK")

if __name__ == '__main__':
    main()