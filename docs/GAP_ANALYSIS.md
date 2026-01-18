# Gap Analysis
## Gaps

*No open gaps at this time.*

---

**Resolved gaps have been moved to [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md).**

Recent resolutions (January 17, 2026):
- GAP-0225: CANARY markers outside src/ normalized and CI now runs repo-wide lint
- GAP-0226: STATUS=IMPLEMENTED replaced with valid values (COMPLETE/TESTED)
- GAP-0227: canaryscan verify step added to CI
- GAP-0228: Conformance sync scanner now enforces --fail-on-issues
- GAP-0229: REQ-DOC report generator tool and CI job created (see `reports/` artifacts)
- GAP-0230: REQ-GQL-TYPE-CONV-001 marker fixed and now in status.csv
- GAP-0231: REQ-GQL-VALUES-MATCH-001 promoted to TESTED
- GAP-0232: REQ-PERF-PHASE5-003 STRING_CONCAT promoted to BENCHED

## REQ-DOC Report Tool

To generate requirement ID reports for GitLab issues:

```bash
# Generate all reports
python3 tools/req_doc_report.py --all-issues

# Generate GitLab-ready snippets for copy-paste
python3 tools/req_doc_report.py --all-issues --gitlab-snippet

# Generate report for specific issue
python3 tools/req_doc_report.py --issue 305 --gitlab-snippet

# View requirement summary
python3 tools/req_doc_report.py --summary
```

Reports are also generated automatically in CI as artifacts.
