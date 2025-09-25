#!/usr/bin/env python3
"""Generate status.csv from CANARY annotations in the codebase."""

import sys
import pathlib
import re
import csv
from typing import Dict, List, Tuple
from dataclasses import dataclass
from datetime import datetime

@dataclass
class CanaryEntry:
    req_id: str
    feature: str
    aspect: str
    status: str
    test: str
    bench: str
    owner: str
    updated: str
    file_path: str
    line_num: int

CANARY_PATTERN = re.compile(
    r'CANARY:\s*REQ=([^;]+);\s*FEATURE="([^"]+)";\s*ASPECT=([^;]+);\s*'
    r'STATUS=([^;]+);\s*TEST=([^;]+);\s*(?:BENCH=([^;]+);\s*)?'
    r'OWNER=([^;]+);\s*UPDATED=([^;]+)'
)

def parse_canary_line(line: str, file_path: str, line_num: int) -> CanaryEntry:
    """Parse a CANARY annotation line."""
    match = CANARY_PATTERN.search(line)
    if not match:
        return None
    
    groups = match.groups()
    return CanaryEntry(
        req_id=groups[0].strip(),
        feature=groups[1].strip(),
        aspect=groups[2].strip(),
        status=groups[3].strip(),
        test=groups[4].strip(),
        bench=groups[5].strip() if groups[5] else "",
        owner=groups[6].strip(),
        updated=groups[7].strip(),
        file_path=str(file_path),
        line_num=line_num
    )

def scan_file(path: pathlib.Path) -> List[CanaryEntry]:
    """Scan a file for CANARY annotations."""
    entries = []
    try:
        with open(path, 'r') as f:
            for line_num, line in enumerate(f, 1):
                if 'CANARY:' in line:
                    entry = parse_canary_line(line, path, line_num)
                    if entry:
                        entries.append(entry)
    except Exception:
        pass
    return entries

def aggregate_status(entries: List[CanaryEntry]) -> Dict[str, Dict]:
    """Aggregate entries by REQ ID."""
    aggregated = {}
    
    for entry in entries:
        req_id = entry.req_id
        if req_id not in aggregated:
            aggregated[req_id] = {
                'feature': entry.feature,
                'aspects': [],
                'status': 'STUB',
                'tests': set(),
                'benches': set(),
                'owners': set(),
                'last_updated': entry.updated,
                'locations': []
            }
        
        agg = aggregated[req_id]
        agg['aspects'].append(entry.aspect)
        agg['tests'].add(entry.test) if entry.test else None
        agg['benches'].add(entry.bench) if entry.bench else None
        agg['owners'].add(entry.owner)
        agg['locations'].append(f"{entry.file_path}:{entry.line_num}")
        
        # Update status based on priority
        if entry.status == 'BENCHED':
            agg['status'] = 'BENCHED'
        elif entry.status == 'TESTED' and agg['status'] != 'BENCHED':
            agg['status'] = 'TESTED'
        elif entry.status == 'IMPLEMENTED' and agg['status'] == 'STUB':
            agg['status'] = 'IMPLEMENTED'
        
        # Track most recent update
        if entry.updated > agg['last_updated']:
            agg['last_updated'] = entry.updated
    
    return aggregated

def write_csv(aggregated: Dict[str, Dict], output_path: str):
    """Write aggregated data to CSV."""
    with open(output_path, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['REQ_ID', 'Feature', 'Status', 'Tests', 'Benchmarks', 
                        'Owners', 'Last_Updated', 'Aspects', 'Locations'])
        
        for req_id, data in sorted(aggregated.items()):
            writer.writerow([
                req_id,
                data['feature'],
                data['status'],
                ','.join(sorted(data['tests'] - {''})),
                ','.join(sorted(data['benches'] - {''})),
                ','.join(sorted(data['owners'])),
                data['last_updated'],
                ','.join(data['aspects']),
                ';'.join(data['locations'][:3])  # Limit locations
            ])

def main():
    """Main entry point."""
    if len(sys.argv) != 5 or sys.argv[1] != '--repo' or sys.argv[3] != '--out':
        print("Usage: status_generate.py --repo <path> --out <csv>", file=sys.stderr)
        sys.exit(1)
    
    repo_path = pathlib.Path(sys.argv[2])
    output_path = sys.argv[4]
    
    if not repo_path.exists():
        print(f"Error: {repo_path} does not exist", file=sys.stderr)
        sys.exit(1)
    
    # Scan all source files
    all_entries = []
    for ext in ['.zig', '.py', '.sh']:
        for path in repo_path.rglob(f'*{ext}'):
            if '.git' not in str(path) and 'zig-cache' not in str(path):
                entries = scan_file(path)
                all_entries.extend(entries)
    
    # Aggregate by REQ ID
    aggregated = aggregate_status(all_entries)
    
    # Write CSV
    write_csv(aggregated, output_path)
    
    print(f"STATUS_CSV_WRITTEN path={output_path} items={len(aggregated)}")

if __name__ == '__main__':
    main()