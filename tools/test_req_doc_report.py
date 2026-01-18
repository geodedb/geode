#!/usr/bin/env python3
"""
Unit tests for req_doc_report.py requirement ID report generator.
CANARY: REQ=REQ-CI-REQ-DOC-TEST-001; FEATURE="REQ-DOC Report Unit Tests"; ASPECT=UnitTesting; STATUS=TESTED; TEST=test_req_doc_report.py; OWNER=governance; UPDATED=2026-01-17

Tests for GAP-0229 resolution tool.
"""

import unittest
import os
import sys
import tempfile
import csv

# Add tools directory to path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from req_doc_report import (
    load_status_csv, extract_requirement_ids, filter_by_patterns,
    generate_markdown_report, generate_json_report, generate_gitlab_snippet,
    REQ_DOC_ISSUE_MAPPING
)


class TestLoadStatusCSV(unittest.TestCase):
    """Test status.csv loading."""

    def setUp(self):
        """Create a temporary test CSV file."""
        self.test_csv = tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.csv')
        writer = csv.DictWriter(self.test_csv, fieldnames=[
            'REQ', 'Feature', 'Aspect', 'Status', 'Test', 'Bench', 'Owner', 'Updated', 'File'
        ])
        writer.writeheader()
        writer.writerow({
            'REQ': 'REQ-GQL-001', 'Feature': 'TestFeature', 'Aspect': 'Unit',
            'Status': 'TESTED', 'Test': 'test.zig', 'Bench': '', 'Owner': 'test',
            'Updated': '2026-01-17', 'File': 'src/test.zig'
        })
        writer.writerow({
            'REQ': 'REQ-TXN-001', 'Feature': 'Transaction', 'Aspect': 'Core',
            'Status': 'IMPL', 'Test': '', 'Bench': '', 'Owner': 'engine',
            'Updated': '2026-01-17', 'File': 'src/txn.zig'
        })
        self.test_csv.close()

    def tearDown(self):
        """Remove temporary file."""
        os.unlink(self.test_csv.name)

    def test_load_csv(self):
        """Test loading CSV file."""
        entries = load_status_csv(self.test_csv.name)
        self.assertEqual(len(entries), 2)
        self.assertEqual(entries[0]['REQ'], 'REQ-GQL-001')
        self.assertEqual(entries[1]['REQ'], 'REQ-TXN-001')


class TestExtractRequirementIds(unittest.TestCase):
    """Test requirement ID extraction."""

    def test_extract_by_prefix(self):
        """Test grouping by prefix."""
        entries = [
            {'REQ': 'REQ-GQL-001', 'Feature': 'A'},
            {'REQ': 'REQ-GQL-002', 'Feature': 'B'},
            {'REQ': 'REQ-TXN-001', 'Feature': 'C'},
        ]
        by_prefix = extract_requirement_ids(entries)
        self.assertIn('REQ-GQL', by_prefix)
        self.assertIn('REQ-TXN', by_prefix)
        self.assertEqual(len(by_prefix['REQ-GQL']), 2)
        self.assertEqual(len(by_prefix['REQ-TXN']), 1)

    def test_deduplicate(self):
        """Test that duplicate IDs are removed."""
        entries = [
            {'REQ': 'REQ-GQL-001', 'Feature': 'A'},
            {'REQ': 'REQ-GQL-001', 'Feature': 'B'},  # Duplicate
        ]
        by_prefix = extract_requirement_ids(entries)
        self.assertEqual(len(by_prefix['REQ-GQL']), 1)


class TestFilterByPatterns(unittest.TestCase):
    """Test pattern-based filtering."""

    def test_filter_single_pattern(self):
        """Test filtering with single pattern."""
        entries = [
            {'REQ': 'REQ-GQL-001'},
            {'REQ': 'REQ-TXN-001'},
        ]
        filtered = filter_by_patterns(entries, ['REQ-GQL-'])
        self.assertEqual(len(filtered), 1)
        self.assertEqual(filtered[0]['REQ'], 'REQ-GQL-001')

    def test_filter_multiple_patterns(self):
        """Test filtering with multiple patterns."""
        entries = [
            {'REQ': 'REQ-GQL-001'},
            {'REQ': 'REQ-TXN-001'},
            {'REQ': 'REQ-AUTH-001'},
        ]
        filtered = filter_by_patterns(entries, ['REQ-GQL-', 'REQ-TXN-'])
        self.assertEqual(len(filtered), 2)

    def test_filter_prefix_match(self):
        """Test that patterns match prefixes correctly."""
        entries = [
            {'REQ': 'REQ-SESSION-001'},
            {'REQ': 'REQ-SESSION-SECURITY-001'},
            {'REQ': 'REQ-AUTH-SESSION-001'},
        ]
        filtered = filter_by_patterns(entries, ['REQ-SESSION'])
        self.assertEqual(len(filtered), 2)  # REQ-SESSION-001 and REQ-SESSION-SECURITY-001


class TestReportGeneration(unittest.TestCase):
    """Test report generation functions."""

    def test_markdown_report(self):
        """Test markdown report generation."""
        entries = [
            {'REQ': 'REQ-GQL-001', 'Feature': 'Test', 'Aspect': 'Unit',
             'Status': 'TESTED', 'File': 'test.zig'},
        ]
        report = generate_markdown_report(entries)
        self.assertIn('## Summary', report)
        self.assertIn('TESTED', report)
        self.assertIn('REQ-GQL-001', report)

    def test_json_report(self):
        """Test JSON report generation."""
        entries = [
            {'REQ': 'REQ-GQL-001', 'Status': 'TESTED'},
        ]
        import json
        report = generate_json_report(entries)
        data = json.loads(report)
        self.assertEqual(data['total'], 1)
        self.assertIn('REQ-GQL-001', data['requirement_ids'])

    def test_gitlab_snippet(self):
        """Test GitLab snippet generation."""
        entries = [
            {'REQ': 'REQ-GQL-001'},
            {'REQ': 'REQ-GQL-002'},
        ]
        info = {'title': 'Test', 'source_doc': 'test.md'}
        snippet = generate_gitlab_snippet(entries, info)
        self.assertIn('## Requirement IDs (from doc)', snippet)
        self.assertIn('**Total:** 2 requirements', snippet)
        self.assertIn('`REQ-GQL-001`', snippet)


class TestIssueMappings(unittest.TestCase):
    """Test issue mappings are complete."""

    def test_all_issues_have_required_fields(self):
        """Test that all issue mappings have required fields."""
        required_fields = ['title', 'description', 'patterns', 'source_doc']
        for issue_num, info in REQ_DOC_ISSUE_MAPPING.items():
            for field in required_fields:
                self.assertIn(field, info, f"Issue {issue_num} missing field: {field}")

    def test_issue_293_all_requirements(self):
        """Test that issue 293 matches all requirements."""
        self.assertIn(293, REQ_DOC_ISSUE_MAPPING)
        patterns = REQ_DOC_ISSUE_MAPPING[293]['patterns']
        self.assertIn('REQ-', patterns)  # Matches all REQ- prefixes

    def test_transaction_issues_patterns(self):
        """Test transaction-related issue patterns."""
        # Issue 305: Transaction Management
        self.assertIn('REQ-TXN', REQ_DOC_ISSUE_MAPPING[305]['patterns'])
        # Issue 307: Transaction Isolation
        self.assertIn('REQ-TXN-ISO', REQ_DOC_ISSUE_MAPPING[307]['patterns'])


if __name__ == '__main__':
    unittest.main()
