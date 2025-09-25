#!/usr/bin/env python3
"""
Generate status.csv from CANARY markers in the codebase.
"""

import argparse
import csv
import os
import re
from pathlib import Path
from typing import Dict, List, Tuple


# CANARY pattern: CANARY: REQ=REQ-GQL-XXX; FEATURE="..."; ASPECT=...; STATUS=...; TEST=...; BENCH=...; OWNER=...; UPDATED=...
CANARY_PATTERN = re.compile(
    r'CANARY:\s*'
    r'REQ=(?P<req>[^;]+);\s*'
    r'FEATURE="(?P<feature>[^"]+)";\s*'
    r'ASPECT=(?P<aspect>[^;]+);\s*'
    r'STATUS=(?P<status>[^;]+);\s*'
    r'(?:TEST=(?P<test>[^;]+);\s*)?'
    r'(?:BENCH=(?P<bench>[^;]+);\s*)?'
    r'OWNER=(?P<owner>[^;]+);\s*'
    r'UPDATED=(?P<updated>[^;\s]+)'
)


def find_canary_markers(repo_path: Path) -> List[Dict[str, str]]:
    """Find all CANARY markers in the repository."""
    markers = []
    
    # File extensions to search
    extensions = {'.zig', '.py', '.md', '.sh', '.yaml', '.yml'}
    
    for root, _, files in os.walk(repo_path):
        # Skip hidden directories and vendor directories
        if '/.git' in root or '/vendor' in root or '/zig-cache' in root:
            continue
            
        for file in files:
            file_path = Path(root) / file
            
            # Only process files with relevant extensions
            if file_path.suffix not in extensions:
                continue
            
            try:
                with open(file_path, 'r', encoding='utf-8') as f:
                    content = f.read()
                    
                for match in CANARY_PATTERN.finditer(content):
                    marker = match.groupdict()
                    marker['file'] = str(file_path.relative_to(repo_path))
                    markers.append(marker)
                    
            except (UnicodeDecodeError, PermissionError):
                # Skip binary files or files we can't read
                continue
    
    return markers


def generate_status_csv(markers: List[Dict[str, str]], output_path: Path) -> int:
    """Generate status.csv from CANARY markers."""
    
    # Sort by REQ ID, then by feature, then by aspect
    markers.sort(key=lambda m: (m['req'], m['feature'], m['aspect']))
    
    # Write CSV
    with open(output_path, 'w', newline='') as csvfile:
        fieldnames = ['REQ', 'Feature', 'Aspect', 'Status', 'Test', 'Bench', 'Owner', 'Updated', 'File']
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        
        writer.writeheader()
        for marker in markers:
            writer.writerow({
                'REQ': marker['req'],
                'Feature': marker['feature'],
                'Aspect': marker['aspect'],
                'Status': marker['status'],
                'Test': marker.get('test', ''),
                'Bench': marker.get('bench', ''),
                'Owner': marker['owner'],
                'Updated': marker['updated'],
                'File': marker['file'],
            })
    
    return len(markers)


def main():
    parser = argparse.ArgumentParser(description='Generate status.csv from CANARY markers')
    parser.add_argument('--repo', type=Path, default=Path('.'), help='Repository root path')
    parser.add_argument('--out', type=Path, default=Path('docs/status.csv'), help='Output CSV file path')
    
    args = parser.parse_args()
    
    # Find all CANARY markers
    markers = find_canary_markers(args.repo)
    
    # Generate status.csv
    count = generate_status_csv(markers, args.out)
    
    # Print success message
    print(f"STATUS_CSV_WRITTEN path={args.out} items={count}")
    
    return 0


if __name__ == '__main__':
    exit(main())