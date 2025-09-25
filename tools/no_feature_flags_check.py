#!/usr/bin/env python3
"""
Check for compile-time feature flags in the codebase.
v0.16.0: All features are integrated, no compile-time flags allowed.

CANARY: REQ=REQ-GQL-023; FEATURE="No Feature Flags"; ASPECT=Enforcement; STATUS=TESTED; TEST=no_feature_flags_check; OWNER=build; UPDATED=2025-09-25
"""

import sys
import os
import re
from pathlib import Path
import click

FORBIDDEN_PATTERNS = [
    r'-Dfeature[_-]',
    r'\bfeature_flag\b',  # Word boundary to avoid false positives
    r'@hasDecl\(.*feature',
    r'comptime.*feature',
    r'build\.option.*feature',
]

EXCLUDE_PATHS = [
    '.git',
    'zig-cache',
    'zig-out',
    '.venv',
    '__pycache__',
    'node_modules',
    'vendor',
]

def check_file(filepath: Path) -> list[tuple[int, str]]:
    """Check a single file for feature flags."""
    violations = []
    
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            for line_no, line in enumerate(f, 1):
                for pattern in FORBIDDEN_PATTERNS:
                    if re.search(pattern, line, re.IGNORECASE):
                        violations.append((line_no, line.strip()))
    except (UnicodeDecodeError, PermissionError):
        # Skip binary files or files we can't read
        pass
    
    return violations

def should_check(path: Path) -> bool:
    """Determine if a path should be checked."""
    # Skip excluded directories
    for part in path.parts:
        if part in EXCLUDE_PATHS:
            return False
    
    # Skip this tool itself
    if path.name == 'no_feature_flags_check.py':
        return False
    
    # Check build files and source files
    if path.suffix in ['.zig', '.zon', '.sh', '.yml', '.yaml']:
        return True
    
    # Skip Python files (they might reference the tool)
    if path.suffix == '.py':
        return False
    
    if path.name in ['Makefile', 'build.zig', 'build.zig.zon']:
        return True
    
    return False

@click.command()
@click.option('--repo', default='.', help='Repository root directory')
@click.option('--strict', is_flag=True, help='Exit with error on violations')
def main(repo: str, strict: bool):
    """Check for compile-time feature flags in the repository."""
    repo_path = Path(repo).resolve()
    
    if not repo_path.exists():
        click.echo(f"Error: Repository path {repo_path} does not exist", err=True)
        sys.exit(1)
    
    violations = []
    files_checked = 0
    
    # Walk the repository
    for root, dirs, files in os.walk(repo_path):
        # Remove excluded directories from traversal
        dirs[:] = [d for d in dirs if d not in EXCLUDE_PATHS]
        
        root_path = Path(root)
        for file in files:
            filepath = root_path / file
            
            if should_check(filepath):
                files_checked += 1
                file_violations = check_file(filepath)
                
                if file_violations:
                    for line_no, line in file_violations:
                        violations.append({
                            'file': str(filepath.relative_to(repo_path)),
                            'line': line_no,
                            'content': line
                        })
    
    # Report results
    if violations:
        click.echo("FEATURE_FLAG_FOUND", err=True)
        click.echo(f"\nFound {len(violations)} feature flag violations:", err=True)
        
        for v in violations:
            click.echo(f"  {v['file']}:{v['line']}: {v['content']}", err=True)
        
        if strict:
            sys.exit(2)
    else:
        click.echo("NO_FEATURE_FLAGS_OK")
        click.echo(f"Checked {files_checked} files - no feature flags found")
    
    return 0

if __name__ == '__main__':
    main()