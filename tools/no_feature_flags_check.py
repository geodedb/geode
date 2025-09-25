#!/usr/bin/env python3
"""
Check for compile-time feature flags in the codebase.
Fails if any are found - everything should be built unified.
"""

import os
import re
import sys
import argparse
from pathlib import Path

FEATURE_FLAG_PATTERNS = [
    re.compile(r'-Dfeature_\w+'),
    re.compile(r'@import\("build_options"\)\.feature_'),
    re.compile(r'if\s*\(\s*feature_\w+\s*\)'),
    re.compile(r'comptime\s+if\s*\(\s*feature_'),
]

EXCLUDE_DIRS = {
    'zig-cache',
    'zig-out',
    '.git',
    'node_modules',
    'vendor',
}

def check_file_for_feature_flags(file_path: Path) -> List[str]:
    """Check a single file for feature flags."""
    violations = []
    
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            content = f.read()
            lines = content.split('\n')
            
            for line_num, line in enumerate(lines, 1):
                for pattern in FEATURE_FLAG_PATTERNS:
                    if pattern.search(line):
                        violations.append(f"{file_path}:{line_num}: {line.strip()}")
                        
    except Exception as e:
        print(f"Error reading {file_path}: {e}", file=sys.stderr)
        
    return violations

def check_repo_for_feature_flags(repo_path: Path) -> List[str]:
    """Check entire repository for feature flags."""
    all_violations = []
    
    for file_path in repo_path.rglob('*'):
        # Skip excluded directories
        if any(excl in str(file_path) for excl in EXCLUDE_DIRS):
            continue
            
        # Only check relevant file types
        if not file_path.is_file():
            continue
            
        if file_path.suffix not in ['.zig', '.py', '.sh', '.yml', '.yaml']:
            continue
            
        violations = check_file_for_feature_flags(file_path)
        all_violations.extend(violations)
        
    return all_violations

def main():
    parser = argparse.ArgumentParser(description='Check for compile-time feature flags')
    parser.add_argument('--repo', type=Path, default=Path('.'),
                        help='Repository root path')
    args = parser.parse_args()
    
    violations = check_repo_for_feature_flags(args.repo)
    
    if violations:
        print("FEATURE_FLAG_FOUND", file=sys.stderr)
        print(f"Found {len(violations)} feature flag violations:", file=sys.stderr)
        for violation in violations[:10]:  # Show first 10
            print(f"  {violation}", file=sys.stderr)
        if len(violations) > 10:
            print(f"  ... and {len(violations) - 10} more", file=sys.stderr)
        return 2
    
    print("NO_FEATURE_FLAGS_OK")
    return 0

if __name__ == '__main__':
    sys.exit(main())