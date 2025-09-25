#!/usr/bin/env python3
"""
Generate status.csv from CANARY annotations in the codebase.
v0.16.0: All features tracked via CANARY system.

CANARY: REQ=REQ-GQL-024; FEATURE="Status Generation"; ASPECT=CSVGeneration; STATUS=TESTED; TEST=status_generate; OWNER=tools; UPDATED=2025-09-25
"""

import sys
import os
import re
import csv
from pathlib import Path
from datetime import datetime
import click

CANARY_PATTERN = r'//\s*CANARY:\s*REQ=([^;]+);\s*FEATURE="([^"]+)";\s*ASPECT=([^;]+);\s*STATUS=([^;]+);\s*TEST=([^;]+);\s*(?:BENCH=([^;]+);\s*)?OWNER=([^;]+);\s*UPDATED=([^\s]+)'

EXCLUDE_PATHS = [
    '.git',
    'zig-cache',
    'zig-out',
    '.venv',
    '__pycache__',
    'node_modules',
    'vendor',
]

def extract_canaries(filepath: Path) -> list[dict]:
    """Extract CANARY annotations from a file."""
    canaries = []
    
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            for line_no, line in enumerate(f, 1):
                match = re.search(CANARY_PATTERN, line)
                if match:
                    canary = {
                        'req_id': match.group(1),
                        'feature': match.group(2),
                        'aspect': match.group(3),
                        'status': match.group(4),
                        'test': match.group(5),
                        'bench': match.group(6) or '',
                        'owner': match.group(7),
                        'updated': match.group(8),
                        'file': str(filepath),
                        'line': line_no,
                    }
                    canaries.append(canary)
    except (UnicodeDecodeError, PermissionError):
        # Skip binary files or files we can't read
        pass
    
    return canaries

def should_scan(path: Path) -> bool:
    """Determine if a file should be scanned."""
    # Skip excluded directories
    for part in path.parts:
        if part in EXCLUDE_PATHS:
            return False
    
    # Scan source files
    if path.suffix in ['.zig', '.py', '.go', '.c', '.cpp', '.h']:
        return True
    
    return False

@click.command()
@click.option('--repo', default='.', help='Repository root directory')
@click.option('--out', default='docs/status.csv', help='Output CSV file')
@click.option('--format', type=click.Choice(['csv', 'json']), default='csv', help='Output format')
def main(repo: str, out: str, format: str):
    """Generate status.csv from CANARY annotations."""
    repo_path = Path(repo).resolve()
    out_path = Path(out).resolve()
    
    if not repo_path.exists():
        click.echo(f"Error: Repository path {repo_path} does not exist", err=True)
        sys.exit(1)
    
    # Create output directory if needed
    out_path.parent.mkdir(parents=True, exist_ok=True)
    
    all_canaries = []
    files_scanned = 0
    
    # Walk the repository
    for root, dirs, files in os.walk(repo_path):
        # Remove excluded directories from traversal
        dirs[:] = [d for d in dirs if d not in EXCLUDE_PATHS]
        
        root_path = Path(root)
        for file in files:
            filepath = root_path / file
            
            if should_scan(filepath):
                files_scanned += 1
                canaries = extract_canaries(filepath)
                
                for canary in canaries:
                    # Make file path relative to repo
                    canary['file'] = str(Path(canary['file']).relative_to(repo_path))
                    all_canaries.append(canary)
    
    # Sort by requirement ID and aspect
    all_canaries.sort(key=lambda x: (x['req_id'], x['aspect']))
    
    # Write output
    if format == 'csv':
        with open(out_path, 'w', newline='') as csvfile:
            fieldnames = ['req_id', 'feature', 'aspect', 'status', 'test', 'bench', 'owner', 'updated', 'file', 'line']
            writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
            
            writer.writeheader()
            for canary in all_canaries:
                writer.writerow(canary)
        
        click.echo(f"STATUS_CSV_WRITTEN path={out_path} items={len(all_canaries)}")
    else:
        import json
        with open(out_path, 'w') as f:
            json.dump(all_canaries, f, indent=2)
        
        click.echo(f"STATUS_JSON_WRITTEN path={out_path} items={len(all_canaries)}")
    
    # Summary statistics
    status_counts = {}
    for canary in all_canaries:
        status = canary['status']
        status_counts[status] = status_counts.get(status, 0) + 1
    
    click.echo(f"\nScanned {files_scanned} files, found {len(all_canaries)} CANARY annotations")
    click.echo("Status breakdown:")
    for status, count in sorted(status_counts.items()):
        click.echo(f"  {status}: {count}")
    
    # Check for stale entries (>60 days old)
    today = datetime.now().date()
    stale_count = 0
    for canary in all_canaries:
        try:
            updated = datetime.strptime(canary['updated'], '%Y-%m-%d').date()
            age_days = (today - updated).days
            if age_days > 60:
                stale_count += 1
        except ValueError:
            pass
    
    if stale_count > 0:
        click.echo(f"\nWarning: {stale_count} CANARY entries are >60 days old", err=True)
    
    return 0

if __name__ == '__main__':
    main()