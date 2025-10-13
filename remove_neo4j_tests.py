#!/usr/bin/env python3
"""
Remove all tests marked as skip: true # Neo4j-specific from test spec files.
"""
import re
import sys
from pathlib import Path

def remove_neo4j_tests(file_path):
    """Remove Neo4j-specific tests from a YAML spec file."""
    with open(file_path, 'r') as f:
        lines = f.readlines()

    # Track which lines to keep
    keep_lines = []
    i = 0
    removed_count = 0

    while i < len(lines):
        line = lines[i]

        # Check if this is the start of a test
        if re.match(r'\s+- name:', line):
            # Look ahead to see if it has skip: true # Neo4j-specific
            test_block = [line]
            j = i + 1
            is_neo4j_skip = False
            test_indent = len(line) - len(line.lstrip())

            # Collect the entire test block
            while j < len(lines):
                next_line = lines[j]
                next_indent = len(next_line) - len(next_line.lstrip())

                # Check if this is still part of the test block
                if next_indent <= test_indent and re.match(r'\s+- name:|^\w+:', next_line):
                    # New test or section starting
                    break

                test_block.append(next_line)

                # Check for Neo4j-specific marker
                if re.search(r'skip:\s+true.*#.*Neo4j-specific', next_line):
                    is_neo4j_skip = True

                j += 1

            if is_neo4j_skip:
                # Skip this entire test block
                print(f"Removing Neo4j-specific test at line {i+1}: {line.strip()}")
                removed_count += 1
                i = j
                continue
            else:
                # Keep this test block
                keep_lines.extend(test_block)
                i = j
                continue

        # Keep non-test lines
        keep_lines.append(line)
        i += 1

    if removed_count > 0:
        # Write back the modified content
        with open(file_path, 'w') as f:
            f.writelines(keep_lines)
        print(f"Removed {removed_count} Neo4j-specific tests from {file_path}")
        return removed_count
    else:
        print(f"No Neo4j-specific tests found in {file_path}")
        return 0

def main():
    spec_dir = Path('geodetestlab/specs')

    if not spec_dir.exists():
        print(f"Error: {spec_dir} not found")
        sys.exit(1)

    total_removed = 0

    # Process all YAML files
    for yaml_file in sorted(spec_dir.glob('*.yml')):
        print(f"\nProcessing {yaml_file}...")
        removed = remove_neo4j_tests(yaml_file)
        total_removed += removed

    print(f"\n{'='*60}")
    print(f"Total Neo4j-specific tests removed: {total_removed}")
    print(f"{'='*60}")

if __name__ == '__main__':
    main()
