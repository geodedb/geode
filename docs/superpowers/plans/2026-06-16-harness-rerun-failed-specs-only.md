# Harness Re-run: Failed Specs Only — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the geode `test-harness-integration` CI job fails and re-runs (GitLab `retry:` or a manual "Retry"), it must run **only the specs that did not pass in the previous attempt**, instead of re-running the full ~308-spec / up-to-5h suite.

**Architecture:** A tiny commit-scoped GitLab cache carries the set of not-yet-passing specs across job attempts. A new pure-Python helper (`scripts/ci/harness_rerun.py`) has two subcommands: `select` (decide what to run this attempt — full specs dir on a fresh commit, or a staged temp dir of just the carried-over specs on a retry) and `record` (after the run, rewrite the carry-over set = *specs attempted this run* − *specs that passed*). The harness job is rewired from `make test` to `select → geodetestlab run --specs <RUN_DIR> → record`. No change to the geode-test-harness repo is required (the runner resolves all paths relative to a cwd derived from its own module location, never from the spec file's directory, so staging a subset of `.yml` files into a temp dir is safe — verified at `executor.py:940,991`).

**Tech Stack:** GitLab CI (`.gitlab-ci.yml`, YAML anchors, `cache:` with `when: always`), Python 3 stdlib (`argparse`, `json`, `pathlib`, `shutil`), pytest (CI self-test job, mirrors the existing `migration-guard` / `.governance-python` precedent).

---

## Background facts (verified against the current tree)

- Job: `test-harness-integration` in `.gitlab-ci.yml` (currently ~line 1264). Key parts:
  - `retry: max: 2` on `runner_system_failure | stuck_or_timeout_failure | script_failure` — **this is the re-run we are optimizing.**
  - `script:` builds geode, then `cd ../geode-test-harness` and `GEODE_BINARY=... make test || HARNESS_EXIT=$?`, copies `reports/` to `harness-reports/`, and gates via `scripts/ci/check_harness_results.py reports/results.json`.
  - No job-level `cache:` today → it inherits the top-level default cache (a **list** of two entries at `.gitlab-ci.yml:95`).
- Harness `make test` target = `geodetestlab run --specs geodetestlab-cli/specs --output reports/results.json -j $(PARALLEL_WORKERS)` with `PARALLEL_WORKERS ?= 1` (serial). The CLI entry point is `geodetestlab` (pyproject `geodetestlab = "geodetestlab.cli:main"`), already on PATH in the job (venv + `pip install -e .../geodetestlab-cli`).
- `geodetestlab run` accepts exactly one of `--spec <file>` or `--specs <dir>`. `--specs` globs `*.yml`/`*.yaml`, kills stale servers, and aggregates one `results.json`. We use `--specs <RUN_DIR>` for both full and subset runs.
- `reports/results.json` shape:
  ```json
  {"summary": {"total": N, "passed": P, "failed": F, "skipped": S},
   "specs": [{"spec": "geodetestlab-cli/specs/NAME.yml",
              "summary": {"total": 4, "passed": 4, "failed": 0, "skipped": 0},
              "results": [ ... ]}, ...]}
  ```
  A spec is "passed" iff its `summary.failed == 0` (a fully-skipped spec counts as passed). Spec identity across the on-disk dir and `results.json` is the file **basename** (`NAME.yml`).
- Runner path resolution: `executor.py:940` derives the geode source dir from `Path(__file__)...` (the harness module location) or `$GEODE_SOURCE_DIR`; `executor.py:991` runs bash steps with `cwd=geode_source`. **Nothing resolves relative to the spec file's directory.** Therefore copying selected `.yml` files into a temp dir and running `--specs <tempdir>` does not break any spec (verified: `2pc_frame_limit.yml`'s `cd ../geode-test-harness/runners/frame_probe` and `./zig-out/bin/geode` are cwd-relative, unaffected by spec location).
- GitLab cache is restored at the start of **every** job execution including retries, and `cache:when: always` uploads it even when the job fails. Keying on `$CI_COMMIT_SHA` means a brand-new commit always starts with an empty cache → full run.

---

## File Structure

- **Create** `scripts/ci/harness_rerun.py` — the select/record helper. Pure functions + two argparse subcommands. Single responsibility: decide-what-to-run and record-what-to-rerun. ~150 lines.
- **Create** `scripts/ci/test_harness_rerun.py` — pytest unit + flow tests for the helper.
- **Modify** `.gitlab-ci.yml`:
  - Anchor the two top-level cache entries (`&zig-build-cache`, `&zig-protoc-cache`) so the job can re-list them.
  - Add a job-level `cache:` to `test-harness-integration` = `[*zig-build-cache, *zig-protoc-cache, <commit-scoped failed-specs cache, when: always>]`.
  - Replace the `make test` block in the job's `script:` with the `select → geodetestlab run → record` flow.
  - Add a `harness-rerun-selftest` governance job that runs the pytest file.
  - Update the job's header comment to document the failed-specs-only retry behavior.

---

## Design contract (must hold for every task)

- `select` prints **only the run directory path to STDOUT**; all human-readable logging goes to STDERR (so `RUN_DIR=$(... select ...)` captures a clean path).
- `record` is **best-effort**: it never fails the job. The pass/fail verdict stays with `scripts/ci/check_harness_results.py` (unchanged).
- Carry-over set = `attempted_this_run − passed_this_run`, where `attempted_this_run` = glob of the exact dir passed to `--specs` (= `RUN_DIR`). This re-runs failed specs **and** a timed-out run's unreached tail, and a subset run never resurrects specs that already passed in an earlier attempt.
- An empty carry-over set is written as an **empty file** (== "nothing to re-run" → next `select` chooses a full run). If every carried-over spec has vanished from the specs dir, `select` falls back to a **full** run rather than running zero specs (the gate treats zero specs as a crash).
- Spec identity is the **basename**.

**Verdict semantics (document this; it is intentional):** after a subset retry, "green" means *the previously-failing specs now pass*; specs that passed in attempt 1 are trusted from attempt 1 and not re-executed. This is the explicit goal. Release jobs that `need: test-harness-integration` therefore gate on "attempt-1 passes + each retry-subset passes".

---

## Task 1: Pure-function core of `harness_rerun.py`

**Files:**
- Create: `scripts/ci/harness_rerun.py`
- Test: `scripts/ci/test_harness_rerun.py`

- [ ] **Step 1: Write the failing tests for the pure functions**

Create `scripts/ci/test_harness_rerun.py`:

```python
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
                "summary": {"total": 1, "passed": 0 if failed else 1,
                            "failed": failed, "skipped": 0},
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
    r = _results(("geodetestlab-cli/specs/a.yml", 0),
                 ("geodetestlab-cli/specs/b.yml", 2))
    assert hr.passed_basenames(r) == {"a.yml"}


def test_passed_basenames_counts_skipped_only_as_passed():
    # failed == 0 -> passed, even if it was all skips
    r = {"specs": [{"spec": "x/c.yml",
                    "summary": {"failed": 0, "passed": 0, "skipped": 3}}]}
    assert hr.passed_basenames(r) == {"c.yml"}


def test_passed_basenames_empty_results():
    assert hr.passed_basenames({}) == set()
    assert hr.passed_basenames({"specs": []}) == set()


# ---- compute_rerun -------------------------------------------------------

def test_compute_rerun_includes_failed_and_never_ran():
    # attempted three; results only mention two (one passed, one failed) ->
    # the failed one AND the never-ran one carry over.
    attempted = ["a.yml", "b.yml", "c.yml"]
    r = _results(("geodetestlab-cli/specs/a.yml", 0),
                 ("geodetestlab-cli/specs/b.yml", 1))
    assert hr.compute_rerun(attempted, r) == ["b.yml", "c.yml"]


def test_compute_rerun_all_passed_is_empty():
    attempted = ["a.yml", "b.yml"]
    r = _results(("geodetestlab-cli/specs/a.yml", 0),
                 ("geodetestlab-cli/specs/b.yml", 0))
    assert hr.compute_rerun(attempted, r) == []


# ---- spec_basenames_in_dir ----------------------------------------------

def test_spec_basenames_in_dir(tmp_path):
    d = _make_specs_dir(tmp_path, "a.yml", "b.yaml")
    (d / "notes.txt").write_text("ignore me")
    assert hr.spec_basenames_in_dir(d) == ["a.yml", "b.yaml"]
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python3 -m pytest scripts/ci/test_harness_rerun.py -v`
Expected: FAIL — `harness_rerun.py` does not exist yet (module load error / `AttributeError`).

- [ ] **Step 3: Create `scripts/ci/harness_rerun.py` with the pure functions**

```python
#!/usr/bin/env python3
"""Select / record the failed-spec subset for test-harness-integration reruns.

When the `test-harness-integration` GitLab job fails and GitLab retries it
(`retry: max: 2`) — or an engineer clicks "Retry" — the previous attempt's
full ~308-spec / multi-hour suite would otherwise re-run from scratch. This
helper carries the set of not-yet-passing specs across attempts (via a GitLab
cache keyed on the commit SHA, uploaded with `when: always`) so a retry runs
ONLY those specs.

Two subcommands, both fed the SAME run directory:

  select  — decide what to run THIS attempt.
            * No state file (or empty)  -> FULL run: print the real specs dir.
            * Non-empty state file       -> SUBSET run: stage copies of just the
              listed specs into --stage-dir and print that dir.
            The chosen dir is printed to STDOUT (nothing else); all human-
            readable logging goes to STDERR so `RUN_DIR=$(... select ...)`
            captures a clean path.

  record  — after the run, recompute the carry-over set from the run's
            reports/results.json and write it to the state file:
              rerun_next = (specs attempted this run) - (specs that passed)
            "attempted this run" is the glob of --attempted-dir (the exact dir
            passed to `--specs`), so a run that timed out partway re-runs its
            unreached tail too, and a subset run never resurrects specs that
            passed in an earlier attempt. An empty result writes an empty file
            (== "nothing to re-run").

A spec "passed" iff it ran and recorded zero failed cases (a fully-skipped
spec counts as passed and is not re-run). Spec identity is the file BASENAME,
which is stable between the results.json `spec` field
(`geodetestlab-cli/specs/NAME.yml`) and the on-disk specs dir.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

SPEC_GLOBS = ("*.yml", "*.yaml")


def spec_basenames_in_dir(specs_dir: Path) -> list[str]:
    """Sorted basenames of every spec file in a directory."""
    names: set[str] = set()
    for pattern in SPEC_GLOBS:
        for p in Path(specs_dir).glob(pattern):
            names.add(p.name)
    return sorted(names)


def passed_basenames(results: dict) -> set[str]:
    """Basenames of specs that ran with zero failed cases."""
    passed: set[str] = set()
    for entry in (results.get("specs") or []):
        spec = entry.get("spec")
        if not spec:
            continue
        summary = entry.get("summary") or {}
        if int(summary.get("failed", 0) or 0) == 0:
            passed.add(os.path.basename(spec))
    return passed


def compute_rerun(attempted: list[str], results: dict) -> list[str]:
    """Specs to carry over: attempted this run minus those that passed."""
    return sorted(set(attempted) - passed_basenames(results))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python3 -m pytest scripts/ci/test_harness_rerun.py -v`
Expected: PASS — all 6 tests green.

- [ ] **Step 5: Commit**

```bash
git add scripts/ci/harness_rerun.py scripts/ci/test_harness_rerun.py
git commit -m "feat(ci): add harness_rerun core — failed-spec carry-over computation

Pure functions for the test-harness-integration failed-specs-only retry:
passed_basenames/compute_rerun/spec_basenames_in_dir. Carry-over set =
attempted - passed (covers failures + a timed-out run's unreached tail).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `record` + `select` subcommands and CLI entry point

**Files:**
- Modify: `scripts/ci/harness_rerun.py`
- Test: `scripts/ci/test_harness_rerun.py`

- [ ] **Step 1: Append the failing subcommand + flow tests**

Append to `scripts/ci/test_harness_rerun.py`:

```python
# ---- record --------------------------------------------------------------

def test_record_writes_failed_basename(tmp_path):
    run_dir = _make_specs_dir(tmp_path, "a.yml", "b.yml")
    results_path = tmp_path / "results.json"
    results_path.write_text(json.dumps(
        _results(("geodetestlab-cli/specs/a.yml", 0),
                 ("geodetestlab-cli/specs/b.yml", 1))))
    state = tmp_path / "state" / "rerun_specs.txt"
    rc = hr.main(["record", "--attempted-dir", str(run_dir),
                  "--results", str(results_path), "--state-file", str(state)])
    assert rc == 0
    assert state.read_text().split() == ["b.yml"]


def test_record_subset_only_reconsiders_attempted(tmp_path):
    # A subset retry: only b.yml + c.yml were attempted; b passed, c failed.
    # a.yml passed earlier and is NOT in the run dir -> must NOT reappear.
    run_dir = _make_specs_dir(tmp_path, "b.yml", "c.yml")
    results_path = tmp_path / "results.json"
    results_path.write_text(json.dumps(
        _results(("geodetestlab-cli/specs/b.yml", 0),
                 ("geodetestlab-cli/specs/c.yml", 2))))
    state = tmp_path / "rerun_specs.txt"
    hr.main(["record", "--attempted-dir", str(run_dir),
             "--results", str(results_path), "--state-file", str(state)])
    assert state.read_text().split() == ["c.yml"]


def test_record_all_passed_writes_empty(tmp_path):
    run_dir = _make_specs_dir(tmp_path, "a.yml")
    results_path = tmp_path / "results.json"
    results_path.write_text(json.dumps(
        _results(("geodetestlab-cli/specs/a.yml", 0))))
    state = tmp_path / "rerun_specs.txt"
    hr.main(["record", "--attempted-dir", str(run_dir),
             "--results", str(results_path), "--state-file", str(state)])
    assert state.exists()
    assert state.read_text().strip() == ""


def test_record_missing_results_leaves_state_unchanged(tmp_path):
    run_dir = _make_specs_dir(tmp_path, "a.yml")
    state = tmp_path / "rerun_specs.txt"
    state.write_text("a.yml\n")
    rc = hr.main(["record", "--attempted-dir", str(run_dir),
                  "--results", str(tmp_path / "nope.json"),
                  "--state-file", str(state)])
    assert rc == 0
    assert state.read_text() == "a.yml\n"  # untouched


def test_record_records_timeout_tail(tmp_path):
    # Three specs attempted, results only mention one (run died after a.yml).
    run_dir = _make_specs_dir(tmp_path, "a.yml", "b.yml", "c.yml")
    results_path = tmp_path / "results.json"
    results_path.write_text(json.dumps(
        _results(("geodetestlab-cli/specs/a.yml", 0))))
    state = tmp_path / "rerun_specs.txt"
    hr.main(["record", "--attempted-dir", str(run_dir),
             "--results", str(results_path), "--state-file", str(state)])
    assert state.read_text().split() == ["b.yml", "c.yml"]


# ---- select --------------------------------------------------------------

def test_select_full_when_no_state(tmp_path, capsys):
    specs = _make_specs_dir(tmp_path, "a.yml", "b.yml")
    state = tmp_path / "missing.txt"
    rc = hr.main(["select", "--specs-dir", str(specs),
                  "--state-file", str(state),
                  "--stage-dir", str(tmp_path / "stage")])
    out = capsys.readouterr().out.strip()
    assert rc == 0
    assert out == str(specs)


def test_select_full_when_state_empty(tmp_path, capsys):
    specs = _make_specs_dir(tmp_path, "a.yml")
    state = tmp_path / "empty.txt"
    state.write_text("")
    rc = hr.main(["select", "--specs-dir", str(specs),
                  "--state-file", str(state),
                  "--stage-dir", str(tmp_path / "stage")])
    assert capsys.readouterr().out.strip() == str(specs)


def test_select_subset_stages_only_listed_specs(tmp_path, capsys):
    specs = _make_specs_dir(tmp_path, "a.yml", "b.yml", "c.yml")
    state = tmp_path / "rerun_specs.txt"
    state.write_text("b.yml\nc.yml\n")
    stage = tmp_path / "stage"
    rc = hr.main(["select", "--specs-dir", str(specs),
                  "--state-file", str(state), "--stage-dir", str(stage)])
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
    hr.main(["select", "--specs-dir", str(specs),
             "--state-file", str(state), "--stage-dir", str(stage)])
    assert hr.spec_basenames_in_dir(stage) == ["a.yml"]


def test_select_subset_falls_back_to_full_when_all_missing(tmp_path, capsys):
    specs = _make_specs_dir(tmp_path, "a.yml")
    state = tmp_path / "rerun_specs.txt"
    state.write_text("ghost.yml\n")  # not in specs dir
    rc = hr.main(["select", "--specs-dir", str(specs),
                  "--state-file", str(state),
                  "--stage-dir", str(tmp_path / "stage")])
    assert rc == 0
    assert capsys.readouterr().out.strip() == str(specs)


def test_two_attempt_flow(tmp_path, capsys):
    """End-to-end: full run with 1 failure -> retry runs only that spec."""
    specs = _make_specs_dir(tmp_path, "a.yml", "b.yml", "c.yml")
    state = tmp_path / "state" / "rerun_specs.txt"
    stage = tmp_path / "stage"

    # Attempt 1: select -> full dir
    hr.main(["select", "--specs-dir", str(specs),
             "--state-file", str(state), "--stage-dir", str(stage)])
    assert capsys.readouterr().out.strip() == str(specs)
    # Attempt 1 result: b.yml failed
    r1 = tmp_path / "r1.json"
    r1.write_text(json.dumps(_results(
        ("geodetestlab-cli/specs/a.yml", 0),
        ("geodetestlab-cli/specs/b.yml", 1),
        ("geodetestlab-cli/specs/c.yml", 0))))
    hr.main(["record", "--attempted-dir", str(specs),
             "--results", str(r1), "--state-file", str(state)])
    assert state.read_text().split() == ["b.yml"]

    # Attempt 2: select -> staged subset of just b.yml
    hr.main(["select", "--specs-dir", str(specs),
             "--state-file", str(state), "--stage-dir", str(stage)])
    assert capsys.readouterr().out.strip() == str(stage)
    assert hr.spec_basenames_in_dir(stage) == ["b.yml"]
    # Attempt 2 result: b.yml now passes
    r2 = tmp_path / "r2.json"
    r2.write_text(json.dumps(_results(("geodetestlab-cli/specs/b.yml", 0))))
    hr.main(["record", "--attempted-dir", str(stage),
             "--results", str(r2), "--state-file", str(state)])
    assert state.read_text().strip() == ""  # all clear
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `python3 -m pytest scripts/ci/test_harness_rerun.py -v`
Expected: FAIL — `hr.main` does not exist (`AttributeError: module 'harness_rerun' has no attribute 'main'`).

- [ ] **Step 3: Append `record`, `select`, and `main` to `scripts/ci/harness_rerun.py`**

Append below `compute_rerun` in `scripts/ci/harness_rerun.py`:

```python
def _read_state(state_file: Path) -> list[str]:
    try:
        lines = Path(state_file).read_text().splitlines()
    except OSError:
        return []
    return [ln.strip() for ln in lines if ln.strip()]


def _load_results(path: Path):
    try:
        with Path(path).open() as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def cmd_select(args: argparse.Namespace) -> int:
    specs_dir = Path(args.specs_dir)
    wanted = _read_state(Path(args.state_file))

    if not wanted:
        print(f"[harness-rerun] FULL run: {specs_dir}", file=sys.stderr)
        print(str(specs_dir))
        return 0

    stage_dir = Path(args.stage_dir)
    if stage_dir.exists():
        shutil.rmtree(stage_dir)
    stage_dir.mkdir(parents=True, exist_ok=True)

    staged, missing = 0, []
    for name in wanted:
        src = specs_dir / name
        if src.is_file():
            shutil.copy2(src, stage_dir / name)
            staged += 1
        else:
            missing.append(name)

    if missing:
        print(f"[harness-rerun] WARNING: {len(missing)} listed spec(s) not found "
              f"in {specs_dir} (skipped): {', '.join(missing)}", file=sys.stderr)

    if staged == 0:
        # Every carried-over spec vanished — fall back to a FULL run rather than
        # running zero specs (the gate treats zero specs as a crash).
        print("[harness-rerun] no listed spec survived; falling back to FULL run",
              file=sys.stderr)
        print(str(specs_dir))
        return 0

    print(f"[harness-rerun] SUBSET run: {staged} spec(s) -> {stage_dir}",
          file=sys.stderr)
    for name in spec_basenames_in_dir(stage_dir):
        print(f"[harness-rerun]   - {name}", file=sys.stderr)
    print(str(stage_dir))
    return 0


def cmd_record(args: argparse.Namespace) -> int:
    state_file = Path(args.state_file)
    results = _load_results(Path(args.results))
    if results is None:
        print(f"[harness-rerun] results.json missing/unreadable at {args.results}; "
              f"leaving state file unchanged", file=sys.stderr)
        return 0

    attempted = spec_basenames_in_dir(Path(args.attempted_dir))
    rerun = compute_rerun(attempted, results)

    state_file.parent.mkdir(parents=True, exist_ok=True)
    state_file.write_text("".join(f"{name}\n" for name in rerun))

    if rerun:
        print(f"[harness-rerun] recorded {len(rerun)} spec(s) to re-run on retry "
              f"-> {state_file}", file=sys.stderr)
    else:
        print("[harness-rerun] all attempted specs passed; cleared re-run state",
              file=sys.stderr)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_sel = sub.add_parser("select", help="choose the run dir for this attempt")
    p_sel.add_argument("--specs-dir", required=True)
    p_sel.add_argument("--state-file", required=True)
    p_sel.add_argument("--stage-dir", required=True)
    p_sel.set_defaults(func=cmd_select)

    p_rec = sub.add_parser("record", help="record the carry-over set after a run")
    p_rec.add_argument("--attempted-dir", required=True)
    p_rec.add_argument("--results", required=True)
    p_rec.add_argument("--state-file", required=True)
    p_rec.set_defaults(func=cmd_record)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 4: Run the full test suite to verify it passes**

Run: `python3 -m pytest scripts/ci/test_harness_rerun.py -v`
Expected: PASS — all tests green (16 total).

- [ ] **Step 5: Make the script executable and smoke-test the CLI**

Run:
```bash
chmod +x scripts/ci/harness_rerun.py
python3 scripts/ci/harness_rerun.py select --help
```
Expected: argparse help for the `select` subcommand prints, exit 0.

- [ ] **Step 6: Commit**

```bash
git add scripts/ci/harness_rerun.py scripts/ci/test_harness_rerun.py
git commit -m "feat(ci): harness_rerun select/record subcommands + CLI

select stages just the carried-over specs (or the full dir on a fresh
commit / cleared state); record rewrites the carry-over set after a run.
Best-effort, basename-keyed, with full pytest flow coverage.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Anchor the two top-level cache entries in `.gitlab-ci.yml`

**Files:**
- Modify: `.gitlab-ci.yml` (top-level `cache:` list, currently ~lines 95–109)

- [ ] **Step 1: Add YAML anchors to the two existing cache entries**

Replace this block (the top-level `cache:` list):

```yaml
cache:
  - key: "zig-cache-${CI_COMMIT_REF_SLUG}"
    fallback_keys:
      - "zig-cache-main-protected"
      - "zig-cache-main"
    paths:
      - .zig-cache/
      - zig-cache/
    policy: pull-push
  - key: "zig-protoc-v32.1" # gitleaks:allow -- public cache key name, not a credential
    paths:
      # protoc-linux-x86_64 (host protoc for every linux runner), addressed by
      # the protobuf dep's pinned hash N-V-__8AAGKbngAmNuaBMSXq_WgmQi6N8WVWVKp0moFSTvoJ.
      - zig-cache/p/N-V-__8AAGKbngAmNuaBMSXq_WgmQi6N8WVWVKp0moFSTvoJ/
    policy: pull-push
```

with (only the two `- key:` lines gain a `&anchor` on a new first line of each list item; everything else is byte-identical):

```yaml
cache:
  - &zig-build-cache
    key: "zig-cache-${CI_COMMIT_REF_SLUG}"
    fallback_keys:
      - "zig-cache-main-protected"
      - "zig-cache-main"
    paths:
      - .zig-cache/
      - zig-cache/
    policy: pull-push
  - &zig-protoc-cache
    key: "zig-protoc-v32.1" # gitleaks:allow -- public cache key name, not a credential
    paths:
      # protoc-linux-x86_64 (host protoc for every linux runner), addressed by
      # the protobuf dep's pinned hash N-V-__8AAGKbngAmNuaBMSXq_WgmQi6N8WVWVKp0moFSTvoJ.
      - zig-cache/p/N-V-__8AAGKbngAmNuaBMSXq_WgmQi6N8WVWVKp0moFSTvoJ/
    policy: pull-push
```

- [ ] **Step 2: Verify the YAML still parses and anchors resolve**

Run:
```bash
python3 - <<'PY'
import yaml
d = yaml.safe_load(open(".gitlab-ci.yml"))
c = d["cache"]
assert isinstance(c, list) and len(c) == 2, c
assert c[0]["key"] == "zig-cache-${CI_COMMIT_REF_SLUG}", c[0]
assert c[1]["key"].startswith("zig-protoc"), c[1]
print("OK: top-level cache parses, 2 entries, anchors valid")
PY
```
Expected: `OK: top-level cache parses, 2 entries, anchors valid`

- [ ] **Step 3: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "refactor(ci): anchor the two default cache entries for reuse

No behavior change — adds &zig-build-cache / &zig-protoc-cache anchors so
test-harness-integration can re-list them alongside a new per-commit cache.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Add the per-commit failed-specs cache to `test-harness-integration`

**Files:**
- Modify: `.gitlab-ci.yml` (`test-harness-integration` job — insert a `cache:` key)

- [ ] **Step 1: Add the job-level `cache:` block**

In the `test-harness-integration:` job, insert a `cache:` key immediately **after** the `retry:` block and **before** `before_script:` (so it is a sibling of `variables`, `retry`, `before_script`). The existing `retry:` block ends with:

```yaml
    when:
      - runner_system_failure
      - stuck_or_timeout_failure
      - script_failure
  before_script:
```

Change it to:

```yaml
    when:
      - runner_system_failure
      - stuck_or_timeout_failure
      - script_failure
  cache:
    # A job-level cache: overrides the top-level default entirely, so we
    # re-list the two default Zig caches (anchored above) and ADD a tiny,
    # commit-scoped cache that carries the set of not-yet-passing specs across
    # job retries. `when: always` uploads it even when the job FAILS — that is
    # the whole point: attempt 1 fails -> writes .harness-state/rerun_specs.txt
    # -> the retry restores it and runs ONLY those specs (see the run block
    # below + scripts/ci/harness_rerun.py). Keyed on the commit SHA so a new
    # commit always starts from a full run.
    - *zig-build-cache
    - *zig-protoc-cache
    - key: "harness-failed-specs-${CI_COMMIT_SHA}"
      paths:
        - .harness-state/
      policy: pull-push
      when: always
  before_script:
```

- [ ] **Step 2: Verify the job cache parses and lists three entries**

Run:
```bash
python3 - <<'PY'
import yaml
d = yaml.safe_load(open(".gitlab-ci.yml"))
c = d["test-harness-integration"]["cache"]
keys = [e["key"] for e in c]
assert len(c) == 3, keys
assert keys[0] == "zig-cache-${CI_COMMIT_REF_SLUG}", keys
assert keys[2] == "harness-failed-specs-${CI_COMMIT_SHA}", keys
assert c[2]["when"] == "always" and c[2]["paths"] == [".harness-state/"], c[2]
print("OK: job cache has 3 entries incl. per-commit failed-specs cache (when: always)")
PY
```
Expected: `OK: job cache has 3 entries incl. per-commit failed-specs cache (when: always)`

- [ ] **Step 3: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "feat(ci): per-commit failed-specs cache on test-harness-integration

Carries .harness-state/ (the not-yet-passing spec list) across job retries
via a CI_COMMIT_SHA-keyed cache with when:always (uploads on failure).
Re-lists the two default Zig caches since a job cache overrides the default.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Rewire the run block from `make test` to select → run → record

**Files:**
- Modify: `.gitlab-ci.yml` (`test-harness-integration` job `script:`, the "Running Full Test Harness Suite" block, currently ~lines 1404–1412)

- [ ] **Step 1: Replace the `make test` invocation block**

Replace this block in the job's `script:`:

```yaml
      echo "=== Running Full Test Harness Suite ==="
      source /opt/venv/bin/activate
      cd ../geode-test-harness

      # Run the full spec suite against the freshly built binary.
      # The geodetestlab runner retries failed specs serially, but make
      # still exits with the initial failure count. Check results.json
      # for the post-retry verdict instead.
      GEODE_BINARY="${GEODE_BINARY}" make test || HARNESS_EXIT=$?
```

with:

```yaml
      echo "=== Running Test Harness Suite ==="
      source /opt/venv/bin/activate

      # --- Failed-spec-only retry selection -------------------------------
      # On the FIRST attempt of a commit the per-commit cache is empty, so
      # `select` returns the full specs dir. If a PRIOR attempt of THIS job
      # failed it left ${STATE_FILE} listing the not-yet-passing specs (cached
      # with when:always); `select` then stages copies of just those into
      # ${STAGE_DIR} and returns that dir, so we run ONLY them. After the run
      # `record` rewrites ${STATE_FILE} = (specs attempted this run) - (specs
      # that passed), which also re-runs a timed-out run's unreached tail.
      # The pass/fail verdict still comes from check_harness_results.py below.
      # See scripts/ci/harness_rerun.py.
      STATE_DIR="${CI_PROJECT_DIR}/.harness-state"
      STATE_FILE="${STATE_DIR}/rerun_specs.txt"
      STAGE_DIR="${CI_PROJECT_DIR}/.harness-staging/rerun-specs"
      RERUN="${CI_PROJECT_DIR}/scripts/ci/harness_rerun.py"
      mkdir -p "${STATE_DIR}"

      cd ../geode-test-harness
      SPECS_DIR="geodetestlab-cli/specs"

      RUN_DIR="$(python3 "${RERUN}" select \
        --specs-dir "${SPECS_DIR}" \
        --state-file "${STATE_FILE}" \
        --stage-dir "${STAGE_DIR}")"
      echo "Harness run dir: ${RUN_DIR} ($(ls "${RUN_DIR}"/*.yml 2>/dev/null | wc -l) specs)"

      # Mirror `make test`: --specs directory mode (kills stale servers,
      # aggregates one results.json), serial (-j 1 — the 5h timeout budget
      # assumes serial). The geodetestlab runner retries failed specs serially
      # within a run; results.json is the post-retry verdict checked below.
      GEODE_BINARY="${GEODE_BINARY}" geodetestlab run \
        --specs "${RUN_DIR}" \
        --output reports/results.json \
        -j 1 || HARNESS_EXIT=$?

      # Persist the carry-over set for a possible retry (best-effort; never
      # fails the job — check_harness_results.py owns the pass/fail verdict).
      python3 "${RERUN}" record \
        --attempted-dir "${RUN_DIR}" \
        --results reports/results.json \
        --state-file "${STATE_FILE}" || true
```

Note: the lines AFTER this block (`cp -r reports/ "${CI_PROJECT_DIR}/harness-reports/"`, the `=== Test Harness Results ===` gate via `check_harness_results.py`) are **unchanged** — `cd ../geode-test-harness` is still in effect, `reports/results.json` is still produced, and the gate still owns the verdict.

- [ ] **Step 2: Verify the job script parses and contains the new flow (and no longer calls `make test`)**

Run:
```bash
python3 - <<'PY'
import yaml
d = yaml.safe_load(open(".gitlab-ci.yml"))
script = "\n".join(d["test-harness-integration"]["script"])
assert "harness_rerun.py select" in script, "missing select call"
assert "harness_rerun.py record" in script, "missing record call"
assert "geodetestlab run" in script and "--specs \"${RUN_DIR}\"" in script, "missing runner call"
assert "make test" not in script, "make test should be gone"
assert "check_harness_results.py" in script, "verdict gate must remain"
print("OK: run block rewired to select/run/record; gate intact; make test removed")
PY
```
Expected: `OK: run block rewired to select/run/record; gate intact; make test removed`

- [ ] **Step 3: Shell-lint the new script block (best-effort)**

Run (only if `shellcheck` is installed — otherwise skip):
```bash
command -v shellcheck >/dev/null && \
  python3 - <<'PY' > /tmp/harness_block.sh
import yaml
d = yaml.safe_load(open(".gitlab-ci.yml"))
print("\n".join(l for l in d["test-harness-integration"]["script"]))
PY
command -v shellcheck >/dev/null && shellcheck -S error /tmp/harness_block.sh || echo "shellcheck not present or only style warnings — OK"
```
Expected: no `error`-level findings (style/info warnings are acceptable; the block is embedded YAML, not a standalone script).

- [ ] **Step 4: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "feat(ci): test-harness-integration runs only failed specs on retry

Replace 'make test' with select -> 'geodetestlab run --specs \$RUN_DIR' ->
record. First attempt runs the full dir; a retry runs only the specs that
did not pass last attempt (incl. a timed-out run's unreached tail). The
existing check_harness_results.py gate still owns the verdict.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Add the `harness-rerun-selftest` governance job

**Files:**
- Modify: `.gitlab-ci.yml` (add a job after `migration-guard`, currently ~line 503)

- [ ] **Step 1: Add the self-test job**

Immediately after the `migration-guard` job (after its `echo "✓ Migration guard passed"` line, before the `# ===... Test Stage ...` banner), add:

```yaml
# Unit-tests the failed-spec-only retry selector used by
# test-harness-integration (scripts/ci/harness_rerun.py). Pure Python, no
# build. Runs when the selector, its tests, or the harness CI wiring change.
harness-rerun-selftest:
  extends: .governance-python
  rules:
    - if: '$CI_MERGE_REQUEST_ID'
      changes:
        - "scripts/ci/harness_rerun.py"
        - "scripts/ci/test_harness_rerun.py"
        - ".gitlab-ci.yml"
    - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'
      changes:
        - "scripts/ci/harness_rerun.py"
        - "scripts/ci/test_harness_rerun.py"
        - ".gitlab-ci.yml"
  before_script:
    - pip install --no-cache-dir pytest
  script:
    - |
      echo "=== Unit-testing harness_rerun selector ==="
      python3 -m pytest scripts/ci/test_harness_rerun.py -v
      echo "✓ harness_rerun selftest passed"
```

- [ ] **Step 2: Verify the new job parses and is well-formed**

Run:
```bash
python3 - <<'PY'
import yaml
d = yaml.safe_load(open(".gitlab-ci.yml"))
j = d["harness-rerun-selftest"]
assert j["extends"] == ".governance-python", j
assert any("pytest scripts/ci/test_harness_rerun.py" in s for s in j["script"]), j["script"]
assert any("pip install" in s and "pytest" in s for s in j["before_script"]), j["before_script"]
print("OK: harness-rerun-selftest job present and well-formed")
PY
```
Expected: `OK: harness-rerun-selftest job present and well-formed`

- [ ] **Step 3: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "test(ci): governance job runs harness_rerun unit tests

harness-rerun-selftest (extends .governance-python) runs pytest on
scripts/ci/test_harness_rerun.py when the selector, its tests, or CI wiring
change. Mirrors the migration-guard precedent.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Document the retry behavior in the job header

**Files:**
- Modify: `.gitlab-ci.yml` (the comment header above `test-harness-integration:`, currently ~lines 1260–1263)

- [ ] **Step 1: Update the header comment**

Replace:

```yaml
# Clones the latest geode-test-harness main branch and runs the full spec
# suite against the freshly built Geode binary. Blocks releases on failure.
# =============================================================================

test-harness-integration:
```

with:

```yaml
# Clones the latest geode-test-harness main branch and runs the spec suite
# against the freshly built Geode binary. Blocks releases on failure.
#
# Failed-spec-only retries: the first attempt of a commit runs the FULL spec
# dir. If the job fails and GitLab retries it (retry: max 2) — or someone hits
# "Retry" — the retry runs ONLY the specs that did not pass last attempt (plus
# a timed-out run's unreached tail). State is carried across attempts in a
# per-commit cache (.harness-state/, when: always). A new commit always starts
# from a full run. Mechanism: scripts/ci/harness_rerun.py (select | record),
# unit-tested by the harness-rerun-selftest governance job. Note: a green
# RETRY means "the previously-failing specs now pass"; specs that passed on an
# earlier attempt are trusted from that attempt.
# =============================================================================

test-harness-integration:
```

- [ ] **Step 2: Verify the file still parses**

Run:
```bash
python3 -c "import yaml; yaml.safe_load(open('.gitlab-ci.yml')); print('OK: .gitlab-ci.yml parses')"
```
Expected: `OK: .gitlab-ci.yml parses`

- [ ] **Step 3: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "docs(ci): document failed-spec-only retry on test-harness-integration

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Final verification

**Files:** (none modified — verification only)

- [ ] **Step 1: Run the full unit-test suite**

Run: `python3 -m pytest scripts/ci/test_harness_rerun.py -v`
Expected: PASS — all tests green.

- [ ] **Step 2: End-to-end simulation against REAL spec basenames + a real results.json**

This proves the helper agrees with the live harness schema (uses the real specs dir and a real `reports/results.json` if present).

Run:
```bash
set -e
SPECS="../geode-test-harness/geodetestlab-cli/specs"
TMP="$(mktemp -d)"
STATE="$TMP/rerun_specs.txt"
STAGE="$TMP/stage"

# Fresh commit: empty state -> select returns the full specs dir.
RUN_DIR="$(python3 scripts/ci/harness_rerun.py select --specs-dir "$SPECS" --state-file "$STATE" --stage-dir "$STAGE")"
test "$RUN_DIR" = "$SPECS" && echo "OK: fresh -> full run ($RUN_DIR)"

# Fabricate a results.json with exactly one real spec marked failed.
ONE="$(ls "$SPECS"/*.yml | head -1)"; BASE="$(basename "$ONE")"
cat > "$TMP/results.json" <<JSON
{"summary":{"total":1},"specs":[{"spec":"geodetestlab-cli/specs/$BASE","summary":{"failed":1,"passed":0,"skipped":0}}]}
JSON
# record against the FULL dir -> carry-over = every spec except the ones that
# "passed" (here only $BASE appears, failed) => all-but-none... so assert $BASE present.
python3 scripts/ci/harness_rerun.py record --attempted-dir "$SPECS" --results "$TMP/results.json" --state-file "$STATE"
grep -qx "$BASE" "$STATE" && echo "OK: record carried over $BASE"

# Retry: select now stages a subset that INCLUDES $BASE.
RUN_DIR2="$(python3 scripts/ci/harness_rerun.py select --specs-dir "$SPECS" --state-file "$STATE" --stage-dir "$STAGE")"
test "$RUN_DIR2" = "$STAGE" && ls "$STAGE/$BASE" >/dev/null && echo "OK: retry -> subset staged incl. $BASE"
rm -rf "$TMP"
echo "ALL E2E CHECKS PASSED"
```
Expected: ends with `ALL E2E CHECKS PASSED`. (Note: because the fabricated `results.json` lists only one spec as failed and none as passed, `record` against the full dir carries over *every* spec; the meaningful assertion is that `$BASE` is present and the retry stages it. The two-attempt subset narrowing is fully exercised by `test_two_attempt_flow` in Step 1.)

- [ ] **Step 3: Validate the whole pipeline with `glab ci lint` (if available)**

Run:
```bash
command -v glab >/dev/null && glab ci lint .gitlab-ci.yml || \
  python3 -c "import yaml; yaml.safe_load(open('.gitlab-ci.yml')); print('glab not present — YAML parse OK')"
```
Expected: `Valid` (glab) or `glab not present — YAML parse OK`.

- [ ] **Step 4: Confirm clean working tree and review the diff**

Run:
```bash
git status
git log --oneline -7
git diff --stat HEAD~6..HEAD 2>/dev/null || true
```
Expected: working tree clean; the new commits present; `.gitlab-ci.yml`, `scripts/ci/harness_rerun.py`, and `scripts/ci/test_harness_rerun.py` are the only changed paths.

---

## Self-Review (completed during planning)

- **Spec coverage:** "only run failed specs on re-run" → Tasks 1–2 (carry-over computation + staging) and Task 5 (CI wiring). "Persist across GitLab retries" → Tasks 3–4 (per-commit cache, `when: always`). "Don't lose a timed-out run's tail" → `compute_rerun` uses *attempted − passed* (Task 1 `test_compute_rerun_includes_failed_and_never_ran`, Task 2 `test_record_records_timeout_tail`). "Fresh commit runs full suite" → commit-SHA cache key + empty-state `select` (Task 2 `test_select_full_when_no_state`). "Don't regress the verdict gate" → `check_harness_results.py` left intact (Task 5 Step 2 asserts it). "No harness-repo change" → verified path resolution (Background facts).
- **Placeholder scan:** none — every step has runnable code/commands and expected output.
- **Type/name consistency:** `passed_basenames`, `compute_rerun`, `spec_basenames_in_dir`, `cmd_select`, `cmd_record`, `main` are used identically in tests (Tasks 1–2) and CI (Task 5). State file `.harness-state/rerun_specs.txt`, stage dir `.harness-staging/rerun-specs`, cache key `harness-failed-specs-${CI_COMMIT_SHA}`, anchors `&zig-build-cache`/`&zig-protoc-cache` are spelled identically across Tasks 3–7.

---

## Risks & mitigations

- **Subset run masks a real cross-spec interaction** (a spec that only fails when run after another). Mitigation: documented verdict semantics (header + this plan); the goal explicitly accepts trusting attempt-1 passes. A new commit always re-runs the full suite, so any masked interaction surfaces on the next push.
- **Harness `main` drifts between attempt 1 and attempt 2** (a carried-over spec is renamed/removed upstream mid-retry). Mitigation: `select` skips missing specs with a warning and falls back to a full run if *all* carried-over specs vanished (`test_select_subset_falls_back_to_full_when_all_missing`).
- **Cache not uploaded on failure** would break the whole feature. Mitigation: `when: always` on the per-commit cache entry, asserted in Task 4 Step 2.
- **`select` stdout contamination** would corrupt `RUN_DIR`. Mitigation: all logging goes to STDERR; tests assert STDOUT is exactly the dir (`test_select_*` use `capsys.readouterr().out`).
