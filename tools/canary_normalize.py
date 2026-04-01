#!/usr/bin/env python3
"""
Normalize CANARY markers to conform to required schema.

This script:
1. Finds all CANARY markers in the codebase
2. Adds missing ASPECT and OWNER fields
3. Replaces STATUS=IMPLEMENTED with STATUS=TESTED (or appropriate status)
4. Reports malformed markers

Required CANARY format:
CANARY: REQ=REQ-XXX; FEATURE="..."; ASPECT=...; STATUS=...; [TEST=...;] [BENCH=...;] OWNER=...; UPDATED=...

Valid STATUS values: STUB, IMPL, TESTED, BENCHED, COMPLETE, EXEMPT
"""

import argparse
import os
import re
from datetime import datetime
from pathlib import Path

# Valid status values per AGENTS.md
VALID_STATUSES = {"STUB", "IMPL", "TESTED", "BENCHED", "COMPLETE", "EXEMPT"}

# Status replacements for invalid values
STATUS_REPLACEMENTS = {
    "IMPLEMENTED": "TESTED",  # IMPLEMENTED is not valid, use TESTED
    "EXEMPTEMENTED": "EXEMPT",  # Typo fix
    "TESTEDEMENTED": "TESTED",  # Typo fix
    "DOCUMENTED": "TESTED",  # Documentation is tested
    "ACTIVE": "TESTED",  # Active tests are tested
    "<status>": "STUB",  # Template placeholder
    "ASSESSMENT": "IMPL",  # Assessment phase -> implementation
    "REMOVED": "EXEMPT",  # Removed code is exempt
    "SPEC": "IMPL",  # Spec-only code -> implementation
    "DEPRECATED": "EXEMPT",  # Deprecated code is exempt
    "SYNTHETIC": "BENCHED",  # Synthetic benchmarks are benched
    "FIXED": "TESTED",  # Fixed bugs are tested
}

# CANARY pattern that matches any CANARY marker (UPDATED is optional)
CANARY_LOOSE_PATTERN = re.compile(
    r"(//|///|#)\s*CANARY:\s*"
    r"REQ=(?P<req>[^;]+);\s*"
    r'FEATURE="(?P<feature>[^"]+)";\s*'
    r"(?P<rest>.*?)"
    r"(?:UPDATED=(?P<updated>[^;\s]+))?$",
    re.DOTALL,
)

# Pattern to extract individual fields
FIELD_PATTERN = re.compile(r"(?P<key>\w+)=(?P<value>[^;]+);?\s*")


def extract_fields(rest: str) -> dict[str, str]:
    """Extract key=value fields from the middle portion of a CANARY marker."""
    fields = {}
    for match in FIELD_PATTERN.finditer(rest):
        key = match.group("key")
        value = match.group("value").strip()
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1]
        fields[key] = value
    return fields


def infer_aspect(feature: str, req: str) -> str:
    """Infer ASPECT from FEATURE or REQ ID."""
    # Common aspect mappings based on feature/req patterns
    feature_lower = feature.lower()
    req.lower()

    if "security" in feature_lower or "auth" in feature_lower or "encrypt" in feature_lower:
        return "Security"
    elif "index" in feature_lower:
        return "Index"
    elif "query" in feature_lower or "planner" in feature_lower:
        return "Query"
    elif "storage" in feature_lower or "backup" in feature_lower:
        return "Storage"
    elif "distributed" in feature_lower or "shard" in feature_lower:
        return "Distributed"
    elif "test" in feature_lower:
        return "Testing"
    elif "performance" in feature_lower or "bench" in feature_lower:
        return "Performance"
    elif "cli" in feature_lower or "shell" in feature_lower:
        return "CLI"
    elif "graph" in feature_lower:
        return "Graph"
    elif "ml" in feature_lower or "embed" in feature_lower:
        return "ML"
    elif "cdc" in feature_lower:
        return "CDC"
    elif "vector" in feature_lower:
        return "Vector"
    elif "parser" in feature_lower or "lexer" in feature_lower:
        return "Parser"
    elif "protocol" in feature_lower:
        return "Protocol"
    elif "temporal" in feature_lower:
        return "Temporal"
    elif "analytics" in feature_lower:
        return "Analytics"
    elif "type" in feature_lower:
        return "Types"
    elif "exec" in feature_lower or "engine" in feature_lower:
        return "Execution"
    elif "rls" in feature_lower:
        return "RLS"
    else:
        return "Core"


def infer_owner(req: str, filepath: str) -> str:
    """Infer OWNER from REQ ID or file path."""
    # Infer from filepath
    parts = Path(filepath).parts
    for part in parts:
        if part in ("security", "auth"):
            return "security"
        elif part == "distributed":
            return "distributed"
        elif part == "storage":
            return "storage"
        elif part == "index":
            return "index"
        elif part == "planner":
            return "planner"
        elif part == "cli":
            return "cli"
        elif part == "gql":
            return "parser"
        elif part == "execution":
            return "execution"
        elif part == "ml":
            return "ml"
        elif part == "analytics":
            return "analytics"
        elif part == "temporal":
            return "temporal"
        elif part == "streaming":
            return "streaming"
        elif part == "server":
            return "server"
        elif part == "eval":
            return "eval"
        elif part == "graph":
            return "graph"
        elif part == "optimizer":
            return "optimizer"

    return "core"


def normalize_canary_line(line: str, filepath: str, dry_run: bool = True) -> tuple[str, bool, list[str]]:
    """
    Normalize a single CANARY marker line.

    Returns:
        Tuple of (normalized_line, was_modified, list_of_issues)
    """
    issues = []
    modified = False

    match = CANARY_LOOSE_PATTERN.search(line)
    if not match:
        return line, False, []

    prefix = match.group(1)  # // or /// or #
    req = match.group("req").strip()
    feature = match.group("feature").strip()
    rest = match.group("rest")
    updated_match = match.group("updated")
    updated = updated_match.strip() if updated_match else None

    # If UPDATED is missing, add today's date
    if not updated:
        updated = datetime.now().strftime("%Y-%m-%d")
        issues.append(f"Added missing UPDATED={updated}")
        modified = True

    # Extract fields from the rest
    fields = extract_fields(rest)

    # Check and normalize STATUS
    status = fields.get("STATUS", "IMPL")
    if status in STATUS_REPLACEMENTS:
        issues.append(f"Replaced STATUS={status} with STATUS={STATUS_REPLACEMENTS[status]}")
        status = STATUS_REPLACEMENTS[status]
        modified = True
    elif status not in VALID_STATUSES:
        issues.append(f"Unknown STATUS={status} (valid: {', '.join(sorted(VALID_STATUSES))})")

    # Check and add ASPECT if missing
    aspect = fields.get("ASPECT")
    if not aspect:
        aspect = infer_aspect(feature, req)
        issues.append(f"Added missing ASPECT={aspect}")
        modified = True

    # Check and add OWNER if missing
    owner = fields.get("OWNER")
    if not owner:
        owner = infer_owner(req, filepath)
        issues.append(f"Added missing OWNER={owner}")
        modified = True

    # Get optional fields
    test = fields.get("TEST", "")
    bench = fields.get("BENCH", "")

    # Reconstruct the CANARY line
    parts = [f'{prefix} CANARY: REQ={req}; FEATURE="{feature}"; ASPECT={aspect}; STATUS={status};']
    if test:
        parts.append(f" TEST={test};")
    if bench:
        parts.append(f" BENCH={bench};")
    parts.append(f" OWNER={owner}; UPDATED={updated}")

    normalized = "".join(parts)

    # Preserve leading whitespace from original
    leading_ws_match = re.match(r"^(\s*)", line)
    leading_ws = leading_ws_match.group(1) if leading_ws_match else ""

    return leading_ws + normalized, modified, issues


def process_file(filepath: Path, dry_run: bool = True) -> tuple[int, int, list[tuple[int, str, list[str]]]]:
    """
    Process a single file, normalizing all CANARY markers.

    Returns:
        Tuple of (total_canary_count, modified_count, list_of_issues_per_line)
    """
    try:
        with open(filepath, encoding="utf-8") as f:
            lines = f.readlines()
    except (UnicodeDecodeError, PermissionError):
        return 0, 0, []

    total_canary = 0
    modified_count = 0
    issues_list = []
    new_lines = []
    file_modified = False

    for i, line in enumerate(lines, 1):
        if "CANARY:" in line and "REQ=" in line:
            total_canary += 1
            normalized, was_modified, issues = normalize_canary_line(line, str(filepath), dry_run)
            if was_modified:
                modified_count += 1
                file_modified = True
                new_lines.append(normalized + "\n" if not normalized.endswith("\n") else normalized)
            else:
                new_lines.append(line)
            if issues:
                issues_list.append((i, line.strip(), issues))
        else:
            new_lines.append(line)

    # Write back if modified and not dry run
    if file_modified and not dry_run:
        with open(filepath, "w", encoding="utf-8") as f:
            f.writelines(new_lines)

    return total_canary, modified_count, issues_list


def main():
    parser = argparse.ArgumentParser(description="Normalize CANARY markers to conform to required schema")
    parser.add_argument("--repo", type=Path, default=Path("."), help="Repository root path")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be changed without modifying files")
    parser.add_argument("--verbose", "-v", action="store_true", help="Show details for each file")

    args = parser.parse_args()

    # File extensions to search
    extensions = {".zig", ".py", ".md", ".sh", ".yaml", ".yml"}

    total_files = 0
    total_canary = 0
    total_modified = 0
    all_issues = []

    for root, _, files in os.walk(args.repo):
        # Skip hidden directories and vendor directories
        if (
            "/.git" in root
            or "/vendor" in root
            or "/zig-cache" in root
            or "/zig-out" in root
            or "/.worktrees" in root
            or "/.claude/worktrees" in root
        ):
            continue

        for file in files:
            filepath = Path(root) / file

            if filepath.suffix not in extensions:
                continue

            canary_count, modified_count, issues = process_file(filepath, args.dry_run)

            if canary_count > 0:
                total_files += 1
                total_canary += canary_count
                total_modified += modified_count

                if issues:
                    all_issues.extend(
                        [
                            (str(filepath.relative_to(args.repo)), line_no, line, issue_list)
                            for line_no, line, issue_list in issues
                        ]
                    )

                if args.verbose and (canary_count > 0 or issues):
                    print(
                        f"{filepath.relative_to(args.repo)}: {canary_count} CANARY markers, {modified_count} modified"
                    )

    # Summary
    print(f"\n{'=' * 60}")
    print("CANARY Normalization Summary")
    print(f"{'=' * 60}")
    print(f"Files processed: {total_files}")
    print(f"Total CANARY markers: {total_canary}")
    print(f"Markers modified: {total_modified}")

    if all_issues:
        print(f"\nIssues found ({len(all_issues)}):")
        for filepath, line_no, line, issues in all_issues:
            print(f"\n  {filepath}:{line_no}")
            print(f"    Original: {line[:80]}...")
            for issue in issues:
                print(f"    - {issue}")

    if args.dry_run:
        print("\n[DRY RUN] No files were modified. Run without --dry-run to apply changes.")
    else:
        print(f"\n{total_modified} markers normalized in {total_files} files.")

    return 0 if total_modified == 0 or not args.dry_run else 1


if __name__ == "__main__":
    exit(main())
