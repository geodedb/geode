#!/usr/bin/env python3
"""Validate CANARY annotation syntax and cross-check with CSV."""

import sys
import pathlib
import re
import csv
from typing import Set, Dict

CANARY_PATTERN = re.compile(
    r'CANARY:\s*REQ=([^;]+);\s*FEATURE="([^"]+)";\s*ASPECT=([^;]+);\s*'
    r'STATUS=([^;]+);\s*TEST=([^;]*);.*OWNER=([^;]+);\s*UPDATED=(\d{4}-\d{2}-\d{2})'
)

# Accept additional statuses used by security docs (IMPL equivalent of IMPLEMENTED) and REMOVED (historical record)
CANARY_NORMALIZE_STATUS = {
    'IMPL': 'IMPLEMENTED',
    'PARTIAL': 'IMPLEMENTED',  # legacy token, normalized
}
VALID_STATUSES = {'STUB', 'IMPLEMENTED', 'TESTED', 'BENCHED', 'REMOVED'}
VALID_ASPECTS = {
    'Core', 'Parser', 'Executor', 'Storage', 'Network',
    'Security', 'Monitoring', 'Distribution', 'CLI', 'PERFORMANCE', 'SECURITY'
}

# REQ id patterns: original REQ-GQL-### plus security/TDE extended forms
REQ_ID_PATTERNS = [
    re.compile(r'^REQ-GQL-\d{3}$'),
    re.compile(r'^REQ-GQL-TDE-[A-Z0-9\-]+-\d{3}$'),
    re.compile(r'^REQ-GQL-SEC-[A-Z0-9\-]+-\d{3}$'),
    re.compile(r'^REQ-GQL-MFA-[A-Z0-9\-]+-\d{3}$'),
]

def check_canary_syntax(line: str, file_path: str, line_num: int) -> list:
    """Check CANARY annotation syntax."""
    errors = []
    
    if 'CANARY:' not in line:
        return errors
    
    match = CANARY_PATTERN.search(line)
    if not match:
        errors.append(f"{file_path}:{line_num}: Invalid CANARY syntax")
        return errors
    
    req_id, feature, aspect, status, test, owner, updated = match.groups()
    
    # Validate REQ ID format
    if not any(p.match(req_id) for p in REQ_ID_PATTERNS):
        errors.append(f"{file_path}:{line_num}: Invalid REQ ID format: {req_id}")
    
    # Validate status
    status_norm = CANARY_NORMALIZE_STATUS.get(status, status)
    if status_norm not in VALID_STATUSES:
        errors.append(f"{file_path}:{line_num}: Invalid STATUS: {status}")
    
    # Validate date format
    if not re.match(r'^\d{4}-\d{2}-\d{2}$', updated):
        errors.append(f"{file_path}:{line_num}: Invalid date format: {updated}")
    
    # Check test name convention
    if status_norm in {'TESTED', 'BENCHED'} and test:
        if not (test.startswith('TestCANARY_') or test.startswith('BenchmarkCANARY_') or test.startswith('tests/')):
            errors.append(f"{file_path}:{line_num}: Test name should start with TestCANARY_ or BenchmarkCANARY_")
    
    return errors

def scan_repo(repo_path: pathlib.Path) -> tuple:
    """Scan repository for CANARY annotations."""
    all_errors = []
    req_ids = set()
    
    for ext in ['.zig', '.py', '.sh']:
        for path in repo_path.rglob(f'*{ext}'):
            if '.git' not in str(path) and 'zig-cache' not in str(path):
                try:
                    with open(path, 'r') as f:
                        for line_num, line in enumerate(f, 1):
                            errors = check_canary_syntax(line, str(path), line_num)
                            all_errors.extend(errors)
                            
                            # Extract REQ IDs
                            if 'CANARY:' in line:
                                match = re.search(r'REQ=([^;]+);', line)
                                if match:
                                    req_ids.add(match.group(1).strip())
                except Exception as e:
                    all_errors.append(f"{path}: Error reading file: {e}")
    
    return all_errors, req_ids

def cross_check_csv(csv_path: str, req_ids: Set[str]) -> list:
    """Cross-check REQ IDs with CSV."""
    errors = []
    csv_req_ids = set()
    
    try:
        with open(csv_path, 'r') as f:
            reader = csv.DictReader(f)
            for row in reader:
                csv_req_ids.add(row['REQ_ID'])
    except FileNotFoundError:
        errors.append(f"CSV file not found: {csv_path}")
        return errors
    except Exception as e:
        errors.append(f"Error reading CSV: {e}")
        return errors
    
    # Check for mismatches
    in_code_not_csv = req_ids - csv_req_ids
    in_csv_not_code = csv_req_ids - req_ids
    
    if in_code_not_csv:
        errors.append(f"REQ IDs in code but not in CSV: {', '.join(sorted(in_code_not_csv))}")
    
    if in_csv_not_code:
        errors.append(f"REQ IDs in CSV but not in code: {', '.join(sorted(in_csv_not_code))}")
    
    return errors

def main():
    """Main entry point."""
    if len(sys.argv) < 3 or sys.argv[1] != '--repo':
        print("Usage: canary_check.py --repo <path> [--csv <path>]", file=sys.stderr)
        sys.exit(1)
    
    repo_path = pathlib.Path(sys.argv[2])
    csv_path = None
    
    if len(sys.argv) == 5 and sys.argv[3] == '--csv':
        csv_path = sys.argv[4]
    
    # Scan repository
    errors, req_ids = scan_repo(repo_path)
    
    # Cross-check with CSV if provided
    if csv_path:
        csv_errors = cross_check_csv(csv_path, req_ids)
        errors.extend(csv_errors)
    
    # Report results
    if errors:
        print("CANARY validation errors found:", file=sys.stderr)
        for error in errors:
            print(f"  {error}", file=sys.stderr)
        sys.exit(1)
    else:
        print(f"CANARY_CHECK_OK: {len(req_ids)} unique REQ IDs found")

if __name__ == '__main__':
    main()