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
    for entry in results.get("specs") or []:
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
        print(
            f"[harness-rerun] WARNING: {len(missing)} listed spec(s) not found "
            f"in {specs_dir} (skipped): {', '.join(missing)}",
            file=sys.stderr,
        )

    if staged == 0:
        # Every carried-over spec vanished — fall back to a FULL run rather than
        # running zero specs (the gate treats zero specs as a crash).
        print("[harness-rerun] no listed spec survived; falling back to FULL run", file=sys.stderr)
        print(str(specs_dir))
        return 0

    print(f"[harness-rerun] SUBSET run: {staged} spec(s) -> {stage_dir}", file=sys.stderr)
    for name in spec_basenames_in_dir(stage_dir):
        print(f"[harness-rerun]   - {name}", file=sys.stderr)
    print(str(stage_dir))
    return 0


def cmd_record(args: argparse.Namespace) -> int:
    state_file = Path(args.state_file)
    results = _load_results(Path(args.results))
    if results is None:
        print(
            f"[harness-rerun] results.json missing/unreadable at {args.results}; leaving state file unchanged",
            file=sys.stderr,
        )
        return 0

    attempted = spec_basenames_in_dir(Path(args.attempted_dir))
    rerun = compute_rerun(attempted, results)

    state_file.parent.mkdir(parents=True, exist_ok=True)
    state_file.write_text("".join(f"{name}\n" for name in rerun))

    if rerun:
        print(f"[harness-rerun] recorded {len(rerun)} spec(s) to re-run on retry -> {state_file}", file=sys.stderr)
    else:
        print("[harness-rerun] all attempted specs passed; cleared re-run state", file=sys.stderr)
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
