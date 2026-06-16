"""Unit + flow tests for scripts/ci/harness_rerun.py."""

from __future__ import annotations

import importlib.util
import json
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


# ---- record --------------------------------------------------------------


def test_record_writes_failed_basename(tmp_path):
    run_dir = _make_specs_dir(tmp_path, "a.yml", "b.yml")
    results_path = tmp_path / "results.json"
    results_path.write_text(
        json.dumps(
            _results(
                ("geodetestlab-cli/specs/a.yml", 0),
                ("geodetestlab-cli/specs/b.yml", 1),
            )
        )
    )
    state = tmp_path / "state" / "rerun_specs.txt"
    rc = hr.main(
        [
            "record",
            "--attempted-dir",
            str(run_dir),
            "--results",
            str(results_path),
            "--state-file",
            str(state),
        ]
    )
    assert rc == 0
    assert state.read_text().split() == ["b.yml"]


def test_record_subset_only_reconsiders_attempted(tmp_path):
    # A subset retry: only b.yml + c.yml were attempted; b passed, c failed.
    # a.yml passed earlier and is NOT in the run dir -> must NOT reappear.
    run_dir = _make_specs_dir(tmp_path, "b.yml", "c.yml")
    results_path = tmp_path / "results.json"
    results_path.write_text(
        json.dumps(
            _results(
                ("geodetestlab-cli/specs/b.yml", 0),
                ("geodetestlab-cli/specs/c.yml", 2),
            )
        )
    )
    state = tmp_path / "rerun_specs.txt"
    hr.main(
        [
            "record",
            "--attempted-dir",
            str(run_dir),
            "--results",
            str(results_path),
            "--state-file",
            str(state),
        ]
    )
    assert state.read_text().split() == ["c.yml"]


def test_record_all_passed_writes_empty(tmp_path):
    run_dir = _make_specs_dir(tmp_path, "a.yml")
    results_path = tmp_path / "results.json"
    results_path.write_text(json.dumps(_results(("geodetestlab-cli/specs/a.yml", 0))))
    state = tmp_path / "rerun_specs.txt"
    hr.main(
        [
            "record",
            "--attempted-dir",
            str(run_dir),
            "--results",
            str(results_path),
            "--state-file",
            str(state),
        ]
    )
    assert state.exists()
    assert state.read_text().strip() == ""


def test_record_missing_results_leaves_state_unchanged(tmp_path):
    run_dir = _make_specs_dir(tmp_path, "a.yml")
    state = tmp_path / "rerun_specs.txt"
    state.write_text("a.yml\n")
    rc = hr.main(
        [
            "record",
            "--attempted-dir",
            str(run_dir),
            "--results",
            str(tmp_path / "nope.json"),
            "--state-file",
            str(state),
        ]
    )
    assert rc == 0
    assert state.read_text() == "a.yml\n"  # untouched


def test_record_records_timeout_tail(tmp_path):
    # Three specs attempted, results only mention one (run died after a.yml).
    run_dir = _make_specs_dir(tmp_path, "a.yml", "b.yml", "c.yml")
    results_path = tmp_path / "results.json"
    results_path.write_text(json.dumps(_results(("geodetestlab-cli/specs/a.yml", 0))))
    state = tmp_path / "rerun_specs.txt"
    hr.main(
        [
            "record",
            "--attempted-dir",
            str(run_dir),
            "--results",
            str(results_path),
            "--state-file",
            str(state),
        ]
    )
    assert state.read_text().split() == ["b.yml", "c.yml"]


# ---- select --------------------------------------------------------------


def test_select_full_when_no_state(tmp_path, capsys):
    specs = _make_specs_dir(tmp_path, "a.yml", "b.yml")
    state = tmp_path / "missing.txt"
    rc = hr.main(
        [
            "select",
            "--specs-dir",
            str(specs),
            "--state-file",
            str(state),
            "--stage-dir",
            str(tmp_path / "stage"),
        ]
    )
    out = capsys.readouterr().out.strip()
    assert rc == 0
    assert out == str(specs)


def test_select_full_when_state_empty(tmp_path, capsys):
    specs = _make_specs_dir(tmp_path, "a.yml")
    state = tmp_path / "empty.txt"
    state.write_text("")
    hr.main(
        [
            "select",
            "--specs-dir",
            str(specs),
            "--state-file",
            str(state),
            "--stage-dir",
            str(tmp_path / "stage"),
        ]
    )
    assert capsys.readouterr().out.strip() == str(specs)


def test_select_subset_stages_only_listed_specs(tmp_path, capsys):
    specs = _make_specs_dir(tmp_path, "a.yml", "b.yml", "c.yml")
    state = tmp_path / "rerun_specs.txt"
    state.write_text("b.yml\nc.yml\n")
    stage = tmp_path / "stage"
    rc = hr.main(
        [
            "select",
            "--specs-dir",
            str(specs),
            "--state-file",
            str(state),
            "--stage-dir",
            str(stage),
        ]
    )
    out = capsys.readouterr().out.strip()
    assert rc == 0
    assert out == str(stage)
    assert hr.spec_basenames_in_dir(stage) == ["b.yml", "c.yml"]


def test_select_subset_rebuilds_stage_dir(tmp_path, capsys):
    specs = _make_specs_dir(tmp_path, "a.yml", "b.yml")
    stage = tmp_path / "stage"
    stage.mkdir()
    (stage / "stale.yml").write_text("old")  # must be cleared
    state = tmp_path / "rerun_specs.txt"
    state.write_text("a.yml\n")
    hr.main(
        [
            "select",
            "--specs-dir",
            str(specs),
            "--state-file",
            str(state),
            "--stage-dir",
            str(stage),
        ]
    )
    assert hr.spec_basenames_in_dir(stage) == ["a.yml"]


def test_select_subset_falls_back_to_full_when_all_missing(tmp_path, capsys):
    specs = _make_specs_dir(tmp_path, "a.yml")
    state = tmp_path / "rerun_specs.txt"
    state.write_text("ghost.yml\n")  # not in specs dir
    rc = hr.main(
        [
            "select",
            "--specs-dir",
            str(specs),
            "--state-file",
            str(state),
            "--stage-dir",
            str(tmp_path / "stage"),
        ]
    )
    assert rc == 0
    assert capsys.readouterr().out.strip() == str(specs)


def test_two_attempt_flow(tmp_path, capsys):
    """End-to-end: full run with 1 failure -> retry runs only that spec."""
    specs = _make_specs_dir(tmp_path, "a.yml", "b.yml", "c.yml")
    state = tmp_path / "state" / "rerun_specs.txt"
    stage = tmp_path / "stage"

    # Attempt 1: select -> full dir
    hr.main(
        [
            "select",
            "--specs-dir",
            str(specs),
            "--state-file",
            str(state),
            "--stage-dir",
            str(stage),
        ]
    )
    assert capsys.readouterr().out.strip() == str(specs)
    # Attempt 1 result: b.yml failed
    r1 = tmp_path / "r1.json"
    r1.write_text(
        json.dumps(
            _results(
                ("geodetestlab-cli/specs/a.yml", 0),
                ("geodetestlab-cli/specs/b.yml", 1),
                ("geodetestlab-cli/specs/c.yml", 0),
            )
        )
    )
    hr.main(
        [
            "record",
            "--attempted-dir",
            str(specs),
            "--results",
            str(r1),
            "--state-file",
            str(state),
        ]
    )
    assert state.read_text().split() == ["b.yml"]

    # Attempt 2: select -> staged subset of just b.yml
    hr.main(
        [
            "select",
            "--specs-dir",
            str(specs),
            "--state-file",
            str(state),
            "--stage-dir",
            str(stage),
        ]
    )
    assert capsys.readouterr().out.strip() == str(stage)
    assert hr.spec_basenames_in_dir(stage) == ["b.yml"]
    # Attempt 2 result: b.yml now passes
    r2 = tmp_path / "r2.json"
    r2.write_text(json.dumps(_results(("geodetestlab-cli/specs/b.yml", 0))))
    hr.main(
        [
            "record",
            "--attempted-dir",
            str(stage),
            "--results",
            str(r2),
            "--state-file",
            str(state),
        ]
    )
    assert state.read_text().strip() == ""  # all clear
