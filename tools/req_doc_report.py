#!/usr/bin/env python3
"""
Generate requirement ID reports for REQ-DOC GitLab issues.
CANARY: REQ=REQ-CI-REQ-DOC-REPORT-001; FEATURE="Requirement ID Report Generator"; ASPECT=Governance; STATUS=TESTED; TEST=test_req_doc_report.py; OWNER=governance; UPDATED=2026-01-17

This tool extracts requirement IDs from status.csv and generates formatted
reports that can be used to update REQ-DOC issues in GitLab (GAP-0229 fix).

Usage:
    python3 tools/req_doc_report.py --out reports/req_doc_report.md
    python3 tools/req_doc_report.py --issue 305 --out reports/issue_305.md
    python3 tools/req_doc_report.py --json --out reports/req_doc_report.json
"""

import argparse
import csv
import json
import os
import sys
from collections import defaultdict
from pathlib import Path
from typing import Dict, List

# Mapping of REQ-DOC issues to their requirement prefixes/patterns
REQ_DOC_ISSUE_MAPPING = {
    293: {
        "title": "REQ-DOC-STATUS_LEDGER: CANARY status.csv Requirement Ledger",
        "description": "All requirements tracked in status.csv",
        "patterns": ["REQ-"],  # All requirements
        "source_doc": "docs/status.csv",
    },
    305: {
        "title": "REQ-DOC-TRANSACTION_MANAGEMENT: Transaction Management Requirements",
        "description": "Transaction management requirements",
        "patterns": ["REQ-GQL-TXN", "REQ-TXN", "REQ-TRANSACTION", "REQ-GQL-TRANSACTION", "REQ-GQL-082"],
        "source_doc": "docs/TRANSACTION_MANAGEMENT.md",
    },
    306: {
        "title": "REQ-DOC-SESSION_MANAGEMENT: Session Management Requirements",
        "description": "Session management requirements",
        "patterns": ["REQ-SESSION", "REQ-GQL-SESSION", "REQ-AUTH-SESSION", "REQ-GQL-081", "REQ-GQL-MFA"],
        "source_doc": "docs/SESSION_MANAGEMENT.md",
    },
    307: {
        "title": "REQ-DOC-ENHANCED_TRANSACTION_ISOLATION: Enhanced Transaction Isolation Requirements",
        "description": "Enhanced transaction isolation requirements",
        "patterns": [
            "REQ-TXN-ISO",
            "REQ-TRANSACTION-ISO",
            "REQ-ISOLATION",
            "REQ-GQL-ISOLATION",
            "REQ-MVCC",
            "REQ-PHANTOM",
            "REQ-TXN-PHANTOM",
        ],
        "source_doc": "docs/ENHANCED_TRANSACTION_ISOLATION.md",
    },
    308: {
        "title": "REQ-DOC-GQL_COMPLIANCE: GQL ISO/IEC 39075:2024 Compliance Guide Requirements",
        "description": "GQL compliance requirements",
        "patterns": ["REQ-GQL-"],  # All GQL requirements
        "source_doc": "docs/GQL_COMPLIANCE.md",
    },
}


def load_status_csv(path: Path) -> List[Dict]:
    """Load status.csv and return list of requirement entries."""
    entries = []
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            entries.append(row)
    return entries


def extract_requirement_ids(entries: List[Dict]) -> Dict[str, List[Dict]]:
    """Extract unique requirement IDs grouped by prefix."""
    by_prefix = defaultdict(list)
    seen = set()

    for entry in entries:
        req_id = entry.get("REQ", "")
        if req_id and req_id not in seen:
            seen.add(req_id)
            # Extract prefix (e.g., REQ-GQL from REQ-GQL-001)
            parts = req_id.split("-")
            if len(parts) >= 2:
                prefix = "-".join(parts[:2])  # REQ-GQL, REQ-TXN, etc.
            else:
                prefix = parts[0]
            by_prefix[prefix].append(entry)

    return dict(by_prefix)


def filter_by_patterns(entries: List[Dict], patterns: List[str]) -> List[Dict]:
    """Filter entries by requirement ID patterns."""
    result = []
    seen = set()

    for entry in entries:
        req_id = entry.get("REQ", "")
        if req_id in seen:
            continue
        for pattern in patterns:
            if req_id.startswith(pattern):
                result.append(entry)
                seen.add(req_id)
                break

    return result


def generate_markdown_report(entries: List[Dict], issue_info: Dict = None) -> str:
    """Generate markdown report for requirements."""
    lines = []

    if issue_info:
        lines.append(f"# {issue_info['title']}")
        lines.append("")
        lines.append(f"**Source:** {issue_info['source_doc']}")
        lines.append(f"**Generated:** {__import__('datetime').datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        lines.append("")

    # Group by status
    by_status = defaultdict(list)
    for entry in entries:
        status = entry.get("Status", "UNKNOWN")
        by_status[status].append(entry)

    # Count summary
    lines.append("## Summary")
    lines.append("")
    lines.append("| Status | Count |")
    lines.append("|--------|-------|")
    total = 0
    for status in sorted(by_status.keys()):
        count = len(by_status[status])
        total += count
        lines.append(f"| {status} | {count} |")
    lines.append(f"| **Total** | **{total}** |")
    lines.append("")

    # Requirement ID list
    lines.append("## Requirement IDs")
    lines.append("")

    for status in ["COMPLETE", "BENCHED", "TESTED", "IMPL", "STUB", "EXEMPT"]:
        if status in by_status:
            lines.append(f"### {status} ({len(by_status[status])})")
            lines.append("")
            for entry in sorted(by_status[status], key=lambda x: x.get("REQ", "")):
                req_id = entry.get("REQ", "")
                feature = entry.get("Feature", "")
                aspect = entry.get("Aspect", "")
                file_path = entry.get("File", "")
                lines.append(f"- `{req_id}` - {feature} ({aspect}) - [{file_path}]({file_path})")
            lines.append("")

    return "\n".join(lines)


def generate_json_report(entries: List[Dict], issue_info: Dict = None) -> str:
    """Generate JSON report for requirements."""
    # Group by status
    by_status = defaultdict(list)
    for entry in entries:
        status = entry.get("Status", "UNKNOWN")
        by_status[status].append(entry.get("REQ", ""))

    result = {
        "generated": __import__("datetime").datetime.now().isoformat(),
        "issue": issue_info,
        "total": len(entries),
        "by_status": {k: sorted(v) for k, v in by_status.items()},
        "requirement_ids": sorted(set(e.get("REQ", "") for e in entries)),
    }

    return json.dumps(result, indent=2)


def generate_gitlab_snippet(entries: List[Dict], issue_info: Dict) -> str:
    """Generate a snippet suitable for pasting into GitLab issue."""
    lines = []

    lines.append("## Requirement IDs (from doc)")
    lines.append("")
    lines.append(f"**Total:** {len(entries)} requirements")
    lines.append("")

    # Group by prefix for readability
    by_prefix = defaultdict(list)
    for entry in entries:
        req_id = entry.get("REQ", "")
        parts = req_id.split("-")
        if len(parts) >= 3:
            prefix = "-".join(parts[:3])  # REQ-GQL-001 -> REQ-GQL
        elif len(parts) >= 2:
            prefix = "-".join(parts[:2])
        else:
            prefix = "OTHER"
        by_prefix[prefix].append(req_id)

    # List IDs grouped by prefix
    for prefix in sorted(by_prefix.keys()):
        ids = sorted(by_prefix[prefix])
        if len(ids) > 10:
            lines.append(f"<details><summary><b>{prefix}*</b> ({len(ids)} IDs)</summary>")
            lines.append("")
            for req_id in ids:
                lines.append(f"- `{req_id}`")
            lines.append("")
            lines.append("</details>")
        else:
            lines.append(f"**{prefix}***")
            for req_id in ids:
                lines.append(f"- `{req_id}`")
        lines.append("")

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Generate requirement ID reports for REQ-DOC issues")
    parser.add_argument("--status-csv", type=Path, default=Path("docs/status.csv"), help="Path to status.csv file")
    parser.add_argument(
        "--issue",
        type=int,
        choices=list(REQ_DOC_ISSUE_MAPPING.keys()),
        help="Generate report for specific GitLab issue number",
    )
    parser.add_argument("--all-issues", action="store_true", help="Generate reports for all REQ-DOC issues")
    parser.add_argument("--out", type=Path, help="Output file path")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    parser.add_argument("--gitlab-snippet", action="store_true", help="Output as GitLab-ready snippet for pasting")
    parser.add_argument("--summary", action="store_true", help="Output summary of all requirement prefixes")

    args = parser.parse_args()

    # Load status.csv
    if not args.status_csv.exists():
        print(f"ERROR: {args.status_csv} not found", file=sys.stderr)
        return 1

    entries = load_status_csv(args.status_csv)
    print(f"Loaded {len(entries)} entries from {args.status_csv}", file=sys.stderr)

    # Generate output based on mode
    if args.summary:
        by_prefix = extract_requirement_ids(entries)
        print(f"\nRequirement ID Prefixes ({len(by_prefix)} groups):")
        for prefix in sorted(by_prefix.keys()):
            count = len(by_prefix[prefix])
            print(f"  {prefix}: {count} entries")
        return 0

    if args.all_issues:
        # Generate reports for all mapped issues
        os.makedirs("reports", exist_ok=True)
        for issue_num, info in REQ_DOC_ISSUE_MAPPING.items():
            filtered = filter_by_patterns(entries, info["patterns"])
            if args.json:
                output = generate_json_report(filtered, info)
                out_path = f"reports/issue_{issue_num}.json"
            elif args.gitlab_snippet:
                output = generate_gitlab_snippet(filtered, info)
                out_path = f"reports/issue_{issue_num}_gitlab.md"
            else:
                output = generate_markdown_report(filtered, info)
                out_path = f"reports/issue_{issue_num}.md"

            with open(out_path, "w") as f:
                f.write(output)
            print(f"Generated {out_path} with {len(filtered)} requirements", file=sys.stderr)
        return 0

    if args.issue:
        info = REQ_DOC_ISSUE_MAPPING[args.issue]
        filtered = filter_by_patterns(entries, info["patterns"])
    else:
        # All requirements
        filtered = entries
        info = REQ_DOC_ISSUE_MAPPING[293]  # Use status ledger info

    # Generate output
    if args.json:
        output = generate_json_report(filtered, info)
    elif args.gitlab_snippet:
        output = generate_gitlab_snippet(filtered, info)
    else:
        output = generate_markdown_report(filtered, info)

    if args.out:
        os.makedirs(args.out.parent, exist_ok=True) if args.out.parent != Path(".") else None
        with open(args.out, "w") as f:
            f.write(output)
        print(f"Written to {args.out}", file=sys.stderr)
    else:
        print(output)

    return 0


if __name__ == "__main__":
    sys.exit(main())
