#!/usr/bin/env python3
"""SONNY-4920: the zig-test pre-push hook must fit its shards to a CPU budget.

The hook started all four ``zig build test -Dtest-shard-index=N`` processes at
once with no ``-j``.  Each Zig build runner sizes its job pool to every CPU it
can see, so four of them oversubscribed the box about four times over.

These tests run the REAL hook command parsed out of ``.pre-commit-config.yaml``
in a scratch directory.  Only the process boundary is substituted: a stub
``nproc`` that reports a chosen CPU count and a stub ``zig`` that records its
argv and environment, holds its slot briefly, and exits with a chosen status.
They check that:

* every shard index 0..3 runs exactly once, with ``-Dtest-shard-total=4``;
* every shard gets an explicit ``-j<N>`` with N >= 1;
* the ``-j`` values of shards running at the same time never add up to more
  than the budget (``nproc``, or ``GEODE_PREPUSH_ZIG_JOBS`` when set);
* a failing or timed-out shard still fails the hook, later shards still run,
  and every shard log is kept and its tail printed;
* CI=1, GEODE_SKIP_SUBPROC_CLUSTER=1 and the per-shard cache dirs are kept.

No real Zig build runs.
"""

from __future__ import annotations

import os
import pathlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from test_sonny4911_cross_gate_status import hook_argv  # noqa: E402

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
HOOK_ID = "zig-test"
SHARDS = 4
OVERRIDE_ENV = "GEODE_PREPUSH_ZIG_JOBS"
TIMEOUT_STATUS = 124
FAILURE_STATUS = 23

# One line per event, appended with a single write so concurrent shards do not
# interleave within a line.  The hold makes shards that may run together
# actually overlap, so the concurrency checks below see real overlap.
STUB_ZIG = r"""#!/bin/sh
idx=
jobs=
cache=
for arg in "$@"; do
    case "$arg" in
        -Dtest-shard-index=*) idx=${arg#-Dtest-shard-index=} ;;
        -j*) jobs=${arg#-j} ;;
    esac
done
prev=
for arg in "$@"; do
    [ "$prev" = --cache-dir ] && cache=$arg
    prev=$arg
done
printf 'start %s %s|%s|CI=%s|SKIP=%s|cache=%s\n' "$idx" "${jobs:-none}" "$*" \
    "${CI:-}" "${GEODE_SKIP_SUBPROC_CLUSTER:-}" "$cache" >> "$STUB_ZIG_LOG"
echo "stub-zig shard $idx output"
sleep "$STUB_ZIG_HOLD"
printf 'end %s\n' "$idx" >> "$STUB_ZIG_LOG"
for fail in $STUB_ZIG_FAIL; do
    case "$fail" in
        "$idx":*) exit "${fail#*:}" ;;
    esac
done
exit 0
"""

STUB_NPROC = """#!/bin/sh
echo "$STUB_NPROC_COUNT"
"""


def expected_peak(budget: int) -> int:
    """Concurrent -j total when the whole budget is split evenly across a wave."""
    return budget if budget < SHARDS else budget - budget % SHARDS


def _write_exec(path: pathlib.Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class PrePushShardBudgetTests(unittest.TestCase):
    """The configured zig-test hook bounds its shards' combined job count."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = pathlib.Path(self._tmp.name)
        self.stub_dir = self.tmp / "bin"
        self.stub_dir.mkdir()
        _write_exec(self.stub_dir / "zig", STUB_ZIG)
        _write_exec(self.stub_dir / "nproc", STUB_NPROC)
        # The hook writes .zig-cache/ under its working directory; run it in
        # a scratch copy so the repository's cache is never touched.
        self.work = self.tmp / "work"
        (self.work / "scripts").mkdir(parents=True)
        shutil.copy2(REPO_ROOT / "scripts" / "hook-env.sh", self.work / "scripts" / "hook-env.sh")
        self.log = self.tmp / "zig.log"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def run_hook(self, cpus: str, override: str | None = None, fail: str = "", hold: str = "1"):
        self.log.write_text("", encoding="utf-8")
        shutil.rmtree(self.work / ".zig-cache", ignore_errors=True)
        env = {k: v for k, v in os.environ.items() if k not in (OVERRIDE_ENV, "CI", "GEODE_SKIP_SUBPROC_CLUSTER")}
        env["PATH"] = f"{self.stub_dir}{os.pathsep}{env.get('PATH', '')}"
        env["STUB_ZIG_LOG"] = str(self.log)
        env["STUB_ZIG_FAIL"] = fail
        env["STUB_ZIG_HOLD"] = hold
        env["STUB_NPROC_COUNT"] = cpus
        if override is not None:
            env[OVERRIDE_ENV] = override
        result = subprocess.run(hook_argv(HOOK_ID), cwd=self.work, capture_output=True, text=True, env=env, timeout=120)
        events = [line for line in self.log.read_text(encoding="utf-8").splitlines() if line]
        return result, events

    def parse(self, events: list[str]):
        """Return ({index: (jobs, argv, env-info)}, max concurrent jobs, max concurrent shards)."""
        starts: dict[int, tuple[int, str, str]] = {}
        running: dict[int, int] = {}
        peak_jobs = 0
        peak_shards = 0
        for event in events:
            if event.startswith("start "):
                head, argv, *info = event.split("|")
                _, idx_s, jobs_s = head.split()
                idx = int(idx_s)
                self.assertNotIn(idx, starts, f"shard {idx} ran more than once:\n" + "\n".join(events))
                self.assertRegex(jobs_s, r"^[0-9]+$", f"shard {idx} ran without an explicit -j<N>: {argv}")
                jobs = int(jobs_s)
                self.assertGreaterEqual(jobs, 1, f"shard {idx} got -j{jobs}")
                starts[idx] = (jobs, argv, "|".join(info))
                running[idx] = jobs
                peak_jobs = max(peak_jobs, sum(running.values()))
                peak_shards = max(peak_shards, len(running))
            elif event.startswith("end "):
                running.pop(int(event.split()[1]))
        self.assertEqual(sorted(starts), list(range(SHARDS)), "\n".join(events))
        return starts, peak_jobs, peak_shards

    def assert_budget(self, events: list[str], budget: int):
        starts, peak_jobs, peak_shards = self.parse(events)
        self.assertLessEqual(
            peak_jobs, budget, f"concurrent -j total {peak_jobs} exceeds budget {budget}:\n" + "\n".join(events)
        )
        for idx, (_jobs, argv, info) in starts.items():
            words = argv.split()
            self.assertEqual(words[:2], ["build", "test"], argv)
            self.assertIn("-Dtest-shard-total=4", words)
            self.assertIn(f"-Dtest-shard-index={idx}", words)
            self.assertIn("--summary", words)
            self.assertIn(f"CI=1|SKIP=1|cache={self.work}/.zig-cache/shard-{idx}", info)
        return starts, peak_jobs, peak_shards

    def assert_logs_kept(self) -> None:
        for idx in range(SHARDS):
            log = self.work / ".zig-cache" / f"pre-push-shard-{idx}.log"
            self.assertTrue(log.is_file(), f"missing {log}")
            self.assertIn(f"stub-zig shard {idx} output", log.read_text(encoding="utf-8"))

    def test_concurrent_jobs_fit_cpu_budget(self) -> None:
        for cpus in (1, 2, 3, 4, 5, 12, 32):
            with self.subTest(cpus=cpus):
                result, events = self.run_hook(str(cpus))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                _starts, peak_jobs, peak_shards = self.assert_budget(events, cpus)
                # Small budgets run in waves; four or more CPUs run every
                # shard together and give the whole budget to the shards.
                self.assertEqual(peak_shards, min(cpus, SHARDS), "\n".join(events))
                self.assertEqual(peak_jobs, expected_peak(cpus), "\n".join(events))
                self.assert_logs_kept()

    def test_override_sets_budget(self) -> None:
        for cpus, override in (("32", "6"), ("2", "8"), ("12", "1")):
            with self.subTest(cpus=cpus, override=override):
                result, events = self.run_hook(cpus, override=override)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                _starts, peak_jobs, _peak_shards = self.assert_budget(events, int(override))
                self.assertEqual(peak_jobs, expected_peak(int(override)), "\n".join(events))

    def test_invalid_budget_is_refused(self) -> None:
        for cpus, override in (("12", "0"), ("12", "abc"), ("12", "-3"), ("12", "08"), ("garbage", None), ("", None)):
            with self.subTest(cpus=cpus, override=override):
                result, events = self.run_hook(cpus, override=override)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(events, [], "shards ran without a valid budget")
                self.assertRegex(result.stdout + result.stderr, r"(nproc|GEODE_PREPUSH_ZIG_JOBS)")

    def test_failure_in_first_wave_still_runs_later_waves_and_fails(self) -> None:
        for cpus in ("1", "2", "12"):
            with self.subTest(cpus=cpus):
                result, events = self.run_hook(cpus, fail=f"0:{FAILURE_STATUS}")
                output = result.stdout + result.stderr
                self.assertNotEqual(result.returncode, 0, output)
                self.assert_budget(events, int(cpus))
                self.assertIn(f"shard 0 FAILED (rc={FAILURE_STATUS})", output)
                self.assertNotIn("shard 1 FAILED", output)
                for idx in range(SHARDS):
                    self.assertIn(f"=== shard {idx} tail (.zig-cache/pre-push-shard-{idx}.log) ===", output)
                    self.assertIn(f"stub-zig shard {idx} output", output)
                self.assert_logs_kept()

    def test_timeout_in_last_shard_fails_with_timeout_message(self) -> None:
        for cpus in ("1", "12"):
            with self.subTest(cpus=cpus):
                result, events = self.run_hook(cpus, fail=f"3:{TIMEOUT_STATUS}")
                output = result.stdout + result.stderr
                self.assertNotEqual(result.returncode, 0, output)
                self.assert_budget(events, int(cpus))
                self.assertIn("shard 3 TIMED OUT after 40m", output)
                self.assert_logs_kept()

    def test_hook_keeps_per_shard_timeout(self) -> None:
        script = hook_argv(HOOK_ID)[-1]
        self.assertRegex(script, r"timeout --signal=TERM --kill-after=60 40m\s*\\?\s*\n?\s*zig build")
        self.assertIsNotNone(re.search(r"\bnproc\b", script), "budget must come from nproc (affinity-aware)")


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False, verbosity=2).result.wasSuccessful() else 1)
