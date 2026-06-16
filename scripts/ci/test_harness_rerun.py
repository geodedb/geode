"""Unit + flow tests for scripts/ci/harness_rerun.py."""

from __future__ import annotations

import importlib.util
from pathlib import Path

# Load the helper module by path (scripts/ci is not a package).
_MOD_PATH = Path(__file__).resolve().parent / "harness_rerun.py"
_spec = importlib.util.spec_from_file_location("harness_rerun", _MOD_PATH)
hr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hr)


def _results(*specs: tuple[str, int]) -> dict:
    """Build a results.json-shaped dict from (spec_path, failed_count) pairs."""
    entries = []
    for spec_path, failed in specs:
        entries.append(
            {
                "spec": spec_path,
                "summary": {"total": 1, "passed": 0 if failed else 1, "failed": failed, "skipped": 0},
                "results": [],
            }
        )
    return {"summary": {"total": len(specs)}, "specs": entries}


def _make_specs_dir(tmp_path: Path, *names: str) -> Path:
    d = tmp_path / "specs"
    d.mkdir()
    for n in names:
        (d / n).write_text(f"name: {n}\n")
    return d


# ---- passed_basenames ----------------------------------------------------


def test_passed_basenames_excludes_failed():
    r = _results(("geodetestlab-cli/specs/a.yml", 0), ("geodetestlab-cli/specs/b.yml", 2))
    assert hr.passed_basenames(r) == {"a.yml"}


def test_passed_basenames_counts_skipped_only_as_passed():
    # failed == 0 -> passed, even if it was all skips
    r = {"specs": [{"spec": "x/c.yml", "summary": {"failed": 0, "passed": 0, "skipped": 3}}]}
    assert hr.passed_basenames(r) == {"c.yml"}


def test_passed_basenames_empty_results():
    assert hr.passed_basenames({}) == set()
    assert hr.passed_basenames({"specs": []}) == set()


# ---- compute_rerun -------------------------------------------------------


def test_compute_rerun_includes_failed_and_never_ran():
    # attempted three; results only mention two (one passed, one failed) ->
    # the failed one AND the never-ran one carry over.
    attempted = ["a.yml", "b.yml", "c.yml"]
    r = _results(("geodetestlab-cli/specs/a.yml", 0), ("geodetestlab-cli/specs/b.yml", 1))
    assert hr.compute_rerun(attempted, r) == ["b.yml", "c.yml"]


def test_compute_rerun_all_passed_is_empty():
    attempted = ["a.yml", "b.yml"]
    r = _results(("geodetestlab-cli/specs/a.yml", 0), ("geodetestlab-cli/specs/b.yml", 0))
    assert hr.compute_rerun(attempted, r) == []


# ---- spec_basenames_in_dir ----------------------------------------------


def test_spec_basenames_in_dir(tmp_path):
    d = _make_specs_dir(tmp_path, "a.yml", "b.yaml")
    (d / "notes.txt").write_text("ignore me")
    assert hr.spec_basenames_in_dir(d) == ["a.yml", "b.yaml"]
