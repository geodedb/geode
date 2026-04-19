"""Pytest for benchmarks/loadtest/compare_ab.py (M0.8).

Runner: 'uvx pytest tests/perf/test_compare_ab_py.py -v' (pytest not in
base env; uvx resolves and runs in a transient venv).
"""

import json
import subprocess
import sys
from pathlib import Path


def _sample(qps, p99_ms, c=4, scenario="ping"):
    return {
        "scenario": scenario,
        "levels": [
            {
                "concurrency": c,
                "total_queries": 100 * c,
                "errors": 0,
                "error_rate": 0,
                "duration": "5s",
                "qps": qps,
                "latency_p50": "1ms",
                "latency_p95": "2ms",
                "latency_p99": f"{p99_ms}ms",
            }
        ],
    }


def _write(tmp_path, name, docs):
    p = tmp_path / name
    with p.open("w") as f:
        json.dump({"scenarios": docs}, f)
    return p


def _run(before, after, format_arg="markdown-rows"):
    script = Path(__file__).parent.parent.parent / "benchmarks" / "loadtest" / "compare_ab.py"
    return subprocess.run(
        [
            sys.executable,
            str(script),
            "--before",
            str(before),
            "--after",
            str(after),
            "--format",
            format_arg,
        ],
        capture_output=True,
        text=True,
    )


def test_no_regression_when_identical(tmp_path):
    b = _write(tmp_path, "b.json", [_sample(1000, 10)])
    a = _write(tmp_path, "a.json", [_sample(1000, 10)])
    r = _run(b, a)
    assert r.returncode == 0, r.stderr
    assert "ping | 4 | 1000" in r.stdout


def test_blocks_on_qps_regression(tmp_path):
    b = _write(tmp_path, "b.json", [_sample(1000, 10)])
    a = _write(tmp_path, "a.json", [_sample(900, 10)])  # -10% tput
    r = _run(b, a, format_arg="exit-code")
    assert r.returncode == 1, r.stdout


def test_blocks_on_p99_regression(tmp_path):
    b = _write(tmp_path, "b.json", [_sample(1000, 10)])
    a = _write(tmp_path, "a.json", [_sample(1000, 12)])  # +20% p99
    r = _run(b, a, format_arg="exit-code")
    assert r.returncode == 1, r.stdout


def test_warn_band_does_not_block(tmp_path):
    b = _write(tmp_path, "b.json", [_sample(1000, 10)])
    a = _write(tmp_path, "a.json", [_sample(960, 10)])  # -4% tput (warn, not block)
    r = _run(b, a, format_arg="exit-code")
    assert r.returncode == 0, r.stdout
