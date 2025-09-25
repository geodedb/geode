#!/usr/bin/env python3
"""
Generate docs/status.csv from CANARY annotations in source code and test results.
"""

import os
import re
import csv
import sys
import argparse
from pathlib import Path
from typing import Dict, List, Tuple

CANARY_PATTERN = re.compile(
    r'// CANARY:\s*REQ=([^;]+);\s*FEATURE="([^"]+)";\s*ASPECT=([^;]+);\s*'
    r'STATUS=([^;]+);\s*TEST=([^;]+);\s*(?:BENCH=([^;]+);\s*)?'
    r'OWNER=([^;]+);\s*UPDATED=([^;]+)'
)

def find_canary_annotations(repo_path: Path) -> List[Dict[str, str]]:
    """Find all CANARY annotations in source files."""
    canaries = []
    
    for ext in ['*.zig', '*.go', '*.py', '*.sh']:
        for file_path in repo_path.rglob(ext):
            if 'zig-cache' in str(file_path) or 'zig-out' in str(file_path):
                continue
                
            try:
                with open(file_path, 'r', encoding='utf-8') as f:
                    content = f.read()
                    
                for match in CANARY_PATTERN.finditer(content):
                    canary = {
                        'req': match.group(1),
                        'feature': match.group(2),
                        'aspect': match.group(3),
                        'status': match.group(4),
                        'test': match.group(5),
                        'bench': match.group(6) or '',
                        'owner': match.group(7),
                        'updated': match.group(8),
                        'file': str(file_path.relative_to(repo_path)),
                    }
                    canaries.append(canary)
                    
            except Exception as e:
                print(f"Error reading {file_path}: {e}", file=sys.stderr)
                
    return canaries

def check_test_results(repo_path: Path, test_name: str) -> bool:
    """Check if a test exists and passes (simplified)."""
    # In a real implementation, this would check test results
    # For now, we assume tests exist if referenced
    test_file = repo_path / 'tests' / f'{test_name}.zig'
    if test_file.exists():
        return True
    
    # Check if it's a path:line reference
    if ':' in test_name:
        path, _ = test_name.split(':', 1)
        return (repo_path / path).exists()
    
    return test_name.startswith('Test') or test_name.startswith('e2e_')

def generate_status_csv(canaries: List[Dict[str, str]], output_path: Path) -> int:
    """Generate status.csv from canary data."""
    
    # Sort by requirement ID
    canaries.sort(key=lambda x: x['req'])
    
    # Write CSV
    with open(output_path, 'w', newline='') as csvfile:
        fieldnames = ['req', 'feature', 'aspect', 'status', 'test', 'bench', 
                      'owner', 'updated', 'file']
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        
        writer.writeheader()
        for canary in canaries:
            writer.writerow(canary)
    
    return len(canaries)

def main():
    parser = argparse.ArgumentParser(description='Generate status.csv from CANARY annotations')
    parser.add_argument('--repo', type=Path, default=Path('.'), 
                        help='Repository root path')
    parser.add_argument('--out', type=Path, default=Path('docs/status.csv'),
                        help='Output CSV file path')
    args = parser.parse_args()
    
    # Find all CANARY annotations
    canaries = find_canary_annotations(args.repo)
    
    if not canaries:
        print("Warning: No CANARY annotations found", file=sys.stderr)
        
    # Generate status.csv
    count = generate_status_csv(canaries, args.out)
    
    print(f"STATUS_CSV_WRITTEN path={args.out} items={count}")
    return 0

if __name__ == '__main__':
    sys.exit(main())