#!/usr/bin/env python3
"""
Integration Test Report Generator

Aggregates test results from all clients and generates a comprehensive HTML report.
"""

import argparse
import json
import os
import sys
from datetime import datetime
from pathlib import Path
from typing import Any


def load_client_results(results_dir: Path) -> dict[str, Any]:
    """Load test results from all client directories."""
    clients = ["geodetestlab", "go", "python", "rust", "zig"]
    results = {}

    for client in clients:
        summary_path = results_dir / client / "summary.json"
        if summary_path.exists():
            try:
                with open(summary_path) as f:
                    results[client] = json.load(f)
            except Exception as e:
                print(f"Warning: Failed to load {client} results: {e}")
                results[client] = {"error": str(e)}
        else:
            results[client] = {"status": "not_found"}

    return results


def calculate_totals(results: dict[str, Any]) -> dict[str, int]:
    """Calculate totals across all clients."""
    totals = {
        "total_tests": 0,
        "passed": 0,
        "failed": 0,
        "clients_passed": 0,
        "clients_failed": 0,
    }

    for client, data in results.items():
        if isinstance(data, dict) and "total_tests" in data:
            totals["total_tests"] += data.get("total_tests", 0)
            totals["passed"] += data.get("passed", 0)
            totals["failed"] += data.get("failed", 0)

            if data.get("exit_code", 1) == 0:
                totals["clients_passed"] += 1
            else:
                totals["clients_failed"] += 1

    return totals


def generate_html_report(results: dict[str, Any], totals: dict[str, int], output_path: Path) -> None:
    """Generate an HTML report from the test results."""

    pass_rate = (totals["passed"] / totals["total_tests"] * 100) if totals["total_tests"] > 0 else 0
    overall_status = "PASSED" if totals["failed"] == 0 and totals["clients_failed"] == 0 else "FAILED"
    status_color = "#22c55e" if overall_status == "PASSED" else "#ef4444"

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Geode Integration Test Report</title>
    <style>
        * {{
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }}
        body {{
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
            background: linear-gradient(135deg, #1e293b 0%, #0f172a 100%);
            min-height: 100vh;
            padding: 2rem;
            color: #e2e8f0;
        }}
        .container {{
            max-width: 1200px;
            margin: 0 auto;
        }}
        .header {{
            text-align: center;
            margin-bottom: 2rem;
        }}
        .header h1 {{
            font-size: 2.5rem;
            font-weight: 700;
            margin-bottom: 0.5rem;
            background: linear-gradient(135deg, #60a5fa 0%, #a78bfa 100%);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }}
        .header p {{
            color: #94a3b8;
        }}
        .summary-card {{
            background: rgba(30, 41, 59, 0.8);
            border-radius: 1rem;
            padding: 2rem;
            margin-bottom: 2rem;
            border: 1px solid rgba(148, 163, 184, 0.1);
        }}
        .summary-grid {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 1.5rem;
        }}
        .stat-box {{
            text-align: center;
            padding: 1rem;
            background: rgba(15, 23, 42, 0.5);
            border-radius: 0.75rem;
        }}
        .stat-value {{
            font-size: 2.5rem;
            font-weight: 700;
        }}
        .stat-label {{
            color: #94a3b8;
            font-size: 0.875rem;
            margin-top: 0.25rem;
        }}
        .status-passed {{ color: #22c55e; }}
        .status-failed {{ color: #ef4444; }}
        .status-pending {{ color: #eab308; }}
        .clients-section {{
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
            gap: 1.5rem;
        }}
        .client-card {{
            background: rgba(30, 41, 59, 0.8);
            border-radius: 1rem;
            padding: 1.5rem;
            border: 1px solid rgba(148, 163, 184, 0.1);
        }}
        .client-header {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 1rem;
        }}
        .client-name {{
            font-size: 1.25rem;
            font-weight: 600;
        }}
        .client-status {{
            padding: 0.25rem 0.75rem;
            border-radius: 9999px;
            font-size: 0.75rem;
            font-weight: 600;
            text-transform: uppercase;
        }}
        .client-status.passed {{
            background: rgba(34, 197, 94, 0.2);
            color: #22c55e;
        }}
        .client-status.failed {{
            background: rgba(239, 68, 68, 0.2);
            color: #ef4444;
        }}
        .client-stats {{
            display: grid;
            grid-template-columns: repeat(3, 1fr);
            gap: 0.75rem;
        }}
        .client-stat {{
            text-align: center;
            padding: 0.75rem;
            background: rgba(15, 23, 42, 0.5);
            border-radius: 0.5rem;
        }}
        .client-stat-value {{
            font-size: 1.5rem;
            font-weight: 700;
        }}
        .client-stat-label {{
            font-size: 0.75rem;
            color: #94a3b8;
        }}
        .footer {{
            text-align: center;
            margin-top: 2rem;
            color: #64748b;
            font-size: 0.875rem;
        }}
        .overall-status {{
            display: inline-block;
            padding: 0.5rem 1.5rem;
            border-radius: 9999px;
            font-size: 1.25rem;
            font-weight: 700;
            text-transform: uppercase;
            background: rgba({int(status_color[1:3], 16)}, {int(status_color[3:5], 16)}, {int(status_color[5:7], 16)}, 0.2);
            color: {status_color};
            margin-bottom: 1.5rem;
        }}
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>Geode Integration Test Report</h1>
            <p>Generated: {datetime.now().strftime("%Y-%m-%d %H:%M:%S")}</p>
        </div>

        <div class="summary-card">
            <div style="text-align: center;">
                <div class="overall-status">{overall_status}</div>
            </div>
            <div class="summary-grid">
                <div class="stat-box">
                    <div class="stat-value">{totals['total_tests']}</div>
                    <div class="stat-label">Total Tests</div>
                </div>
                <div class="stat-box">
                    <div class="stat-value status-passed">{totals['passed']}</div>
                    <div class="stat-label">Passed</div>
                </div>
                <div class="stat-box">
                    <div class="stat-value status-failed">{totals['failed']}</div>
                    <div class="stat-label">Failed</div>
                </div>
                <div class="stat-box">
                    <div class="stat-value">{pass_rate:.1f}%</div>
                    <div class="stat-label">Pass Rate</div>
                </div>
            </div>
        </div>

        <h2 style="font-size: 1.5rem; margin-bottom: 1rem;">Client Results</h2>
        <div class="clients-section">
"""

    client_names = {
        "geodetestlab": "GeodeTestLab",
        "go": "Go Client",
        "python": "Python Client",
        "rust": "Rust Client",
        "zig": "Zig Client",
    }

    for client, data in results.items():
        if isinstance(data, dict) and "total_tests" in data:
            status_class = "passed" if data.get("exit_code", 1) == 0 else "failed"
            status_text = "Passed" if status_class == "passed" else "Failed"
            total = data.get("total_tests", 0)
            passed = data.get("passed", 0)
            failed = data.get("failed", 0)

            html += f"""
            <div class="client-card">
                <div class="client-header">
                    <span class="client-name">{client_names.get(client, client)}</span>
                    <span class="client-status {status_class}">{status_text}</span>
                </div>
                <div class="client-stats">
                    <div class="client-stat">
                        <div class="client-stat-value">{total}</div>
                        <div class="client-stat-label">Total</div>
                    </div>
                    <div class="client-stat">
                        <div class="client-stat-value status-passed">{passed}</div>
                        <div class="client-stat-label">Passed</div>
                    </div>
                    <div class="client-stat">
                        <div class="client-stat-value status-failed">{failed}</div>
                        <div class="client-stat-label">Failed</div>
                    </div>
                </div>
            </div>
"""
        else:
            html += f"""
            <div class="client-card">
                <div class="client-header">
                    <span class="client-name">{client_names.get(client, client)}</span>
                    <span class="client-status failed">No Data</span>
                </div>
                <p style="color: #94a3b8; font-size: 0.875rem;">Results not available</p>
            </div>
"""

    html += """
        </div>

        <div class="footer">
            <p>Geode Graph Database - Docker Integration Test Suite</p>
            <p>For more information, see <a href="https://gitlab.com/devnw/codepros/geode" style="color: #60a5fa;">documentation</a></p>
        </div>
    </div>
</body>
</html>
"""

    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w") as f:
        f.write(html)

    print(f"Report generated: {output_path}")


def main():
    parser = argparse.ArgumentParser(description="Generate integration test report")
    parser.add_argument("--results-dir", default="/results", help="Directory containing test results")
    parser.add_argument("--output", default="/results/integration_report.html", help="Output HTML file path")
    args = parser.parse_args()

    results_dir = Path(args.results_dir)
    output_path = Path(args.output)

    print("=" * 60)
    print("Geode Integration Test Report Generator")
    print("=" * 60)
    print(f"Results Directory: {results_dir}")
    print(f"Output: {output_path}")
    print(f"Timestamp: {datetime.now().isoformat()}")
    print("=" * 60)

    # Load results
    results = load_client_results(results_dir)
    totals = calculate_totals(results)

    # Print summary
    print("\n--- Summary ---")
    print(f"Total Tests: {totals['total_tests']}")
    print(f"Passed: {totals['passed']}")
    print(f"Failed: {totals['failed']}")
    print(f"Clients Passed: {totals['clients_passed']}")
    print(f"Clients Failed: {totals['clients_failed']}")

    # Generate report
    generate_html_report(results, totals, output_path)

    # Also output JSON summary
    json_output = output_path.with_suffix(".json")
    with open(json_output, "w") as f:
        json.dump({
            "timestamp": datetime.now().isoformat(),
            "totals": totals,
            "clients": results,
        }, f, indent=2)
    print(f"JSON summary: {json_output}")

    # Exit with appropriate code
    if totals["failed"] > 0 or totals["clients_failed"] > 0:
        print("\n⚠️  Some tests failed!")
        sys.exit(1)
    else:
        print("\n✅ All tests passed!")
        sys.exit(0)


if __name__ == "__main__":
    main()
