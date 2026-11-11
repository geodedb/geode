#!/usr/bin/env python3
"""SONNY-4911: required cross-build gates must not report success after failure.

Two status-masking defects let a broken cross-build pass the release gates:

1. The pre-push ``cross-compile-check`` hook ran
   ``make cross-compile-required 2>&1 | tail -20`` without ``pipefail``, so the
   pipeline's status was ``tail``'s (always 0) and a failing make was hidden.
2. ``cross-macos-x86_64`` / ``cross-macos-arm64`` ran Zig inside a conditional
   shell recipe followed by an unconditional ``echo "... successful"``.  Make's
   ``/bin/sh -c`` does not run with ``-e``, so the recipe's status was the
   echo's and a compiler failure printed success and exited 0.

These tests execute the REAL committed Makefile targets and the REAL hook
command parsed out of ``.pre-commit-config.yaml``.  Only the command boundary
is substituted: a stub ``zig`` (via ``make ZIG=...``) that exits 19 for chosen
targets, a stub ``make`` on PATH for the hook, and a stub ``uname`` for the
native-macOS skip branch.  No real cross-compile runs.
"""

from __future__ import annotations

import os
import pathlib
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
MAKEFILE = REPO_ROOT / "Makefile"
PRE_COMMIT_CONFIG = REPO_ROOT / ".pre-commit-config.yaml"
HOOK_ID = "cross-compile-check"

COMPILER_FAILURE_STATUS = 19
MAKE_FAILURE_STATUS = 17

# Every required target, the -Dtarget triple and -p prefix its recipe passes to
# Zig, and the success line it prints.  Target lists and build options are part
# of the gate contract, so the positive controls pin them too.
REQUIRED_TARGETS = {
    "cross-linux-x86_64": ("x86_64-linux", "zig-out/linux-x86_64", "✓ Linux x86_64 build successful"),
    "cross-linux-arm64": ("aarch64-linux-gnu", "zig-out/linux-arm64", "✓ Linux ARM64 build successful"),
    "cross-linux-riscv64": ("riscv64-linux-gnu", "zig-out/linux-riscv64", "✓ Linux RISC-V 64-bit build successful"),
    "cross-macos-x86_64": ("x86_64-macos", "zig-out/macos-x86_64", "✓ macOS x86_64 build successful"),
    "cross-macos-arm64": ("aarch64-macos", "zig-out/macos-arm64", "✓ macOS ARM64 build successful"),
}
AGGREGATE_SUCCESS = "✓ All required cross-compilation targets built successfully"
ZIG_FLAGS = "-Dsonny4911-marker=1"

STUB_ZIG = f"""#!/bin/sh
printf '%s\\n' "$*" >> "$STUB_ZIG_LOG"
target=
for arg in "$@"; do
    case "$arg" in -Dtarget=*) target=${{arg#-Dtarget=}} ;; esac
done
for fail in $STUB_ZIG_FAIL_TARGETS; do
    if [ "$fail" = all ] || [ "$fail" = "$target" ]; then
        echo "error: injected compiler failure for $target" >&2
        exit {COMPILER_FAILURE_STATUS}
    fi
done
exit 0
"""

STUB_UNAME = """#!/bin/sh
if [ "$1" = -m ]; then echo "$STUB_UNAME_MACHINE"; else echo "$STUB_UNAME_SYSTEM"; fi
"""

STUB_MAKE = """#!/bin/sh
i=1
while [ "$i" -le 30 ]; do echo "stub-make line $i"; i=$((i + 1)); done
echo "stub-make argv: $*"
exit "$STUB_MAKE_STATUS"
"""


def _write_exec(path: pathlib.Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def _yaml_scalar(raw: str) -> str:
    raw = raw.strip()
    if raw.startswith("'") and raw.endswith("'") and len(raw) >= 2:
        return raw[1:-1].replace("''", "'")
    if raw.startswith('"') and raw.endswith('"') and len(raw) >= 2:
        return bytes(raw[1:-1], "utf-8").decode("unicode_escape")
    return raw


def hook_argv() -> list[str]:
    """Return the argv pre-commit runs for the cross-compile-check hook.

    pre-commit executes ``shlex.split(entry) + args`` (pass_filenames is
    false).  Parsed with a minimal line reader so the test runs on a bare
    python image; cross-checked against PyYAML when it is installed.
    """
    lines = PRE_COMMIT_CONFIG.read_text(encoding="utf-8").splitlines()
    start = next(
        (i for i, line in enumerate(lines) if re.fullmatch(rf"\s*- id: {HOOK_ID}\s*", line)),
        None,
    )
    if start is None:
        raise AssertionError(f"hook {HOOK_ID!r} not found in {PRE_COMMIT_CONFIG}")
    entry = None
    args: list[str] = []
    in_args = False
    for line in lines[start + 1 :]:
        if re.match(r"\s*- (id|repo):", line):
            break
        if in_args:
            item = re.fullmatch(r"\s*- (.*)", line)
            if item:
                args.append(_yaml_scalar(item.group(1)))
                continue
            in_args = False
        key = re.fullmatch(r"\s*(\w+):\s*(.*)", line)
        if not key:
            continue
        if key.group(1) == "entry":
            entry = _yaml_scalar(key.group(2))
        elif key.group(1) == "args":
            if key.group(2).strip():
                raise AssertionError("inline args lists are not supported by this reader")
            in_args = True
    if entry is None:
        raise AssertionError(f"hook {HOOK_ID!r} has no entry")
    argv = shlex.split(entry) + args
    try:
        import yaml  # noqa: PLC0415
    except ImportError:
        return argv
    config = yaml.safe_load(PRE_COMMIT_CONFIG.read_text(encoding="utf-8"))
    hooks = [h for repo in config["repos"] for h in repo.get("hooks", []) if h.get("id") == HOOK_ID]
    if len(hooks) != 1:
        raise AssertionError(f"expected exactly one {HOOK_ID!r} hook, found {len(hooks)}")
    parsed = shlex.split(hooks[0]["entry"]) + list(hooks[0].get("args", []))
    if parsed != argv:
        raise AssertionError(f"hook parse mismatch: {argv!r} != {parsed!r}")
    return argv


def _base_env(stub_dir: pathlib.Path) -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if k not in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL", "ZIG", "ZIG_FLAGS")}
    env["PATH"] = f"{stub_dir}{os.pathsep}{env.get('PATH', '')}"
    return env


class CrossMakeTargetStatusTests(unittest.TestCase):
    """The committed required cross targets propagate compiler status."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.make = shutil.which("make")
        if cls.make is None:
            raise AssertionError("GNU make is required to exercise the committed Makefile")

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = pathlib.Path(self._tmp.name)
        self.stub_dir = self.tmp / "bin"
        self.stub_dir.mkdir()
        self.zig = self.tmp / "zig-stub"
        _write_exec(self.zig, STUB_ZIG)
        self.log = self.tmp / "zig.log"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def run_make(self, target: str, fail_targets: str = "", uname: tuple[str, str] | None = None):
        self.log.write_text("", encoding="utf-8")
        env = _base_env(self.stub_dir)
        env["STUB_ZIG_LOG"] = str(self.log)
        env["STUB_ZIG_FAIL_TARGETS"] = fail_targets
        uname_stub = self.stub_dir / "uname"
        if uname is not None:
            _write_exec(uname_stub, STUB_UNAME)
            env["STUB_UNAME_SYSTEM"], env["STUB_UNAME_MACHINE"] = uname
        elif uname_stub.exists():
            uname_stub.unlink()
        result = subprocess.run(
            [
                self.make,
                "--no-print-directory",
                "-C",
                str(REPO_ROOT),
                "-f",
                str(MAKEFILE),
                f"ZIG={self.zig}",
                f"ZIG_FLAGS={ZIG_FLAGS}",
                target,
            ],
            capture_output=True,
            text=True,
            env=env,
            timeout=60,
        )
        calls = [line for line in self.log.read_text(encoding="utf-8").splitlines() if line]
        return result, calls

    def assert_failed_without_success(self, result, success_lines) -> None:
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, f"gate exited 0 after compiler failure:\n{output}")
        self.assertIn("injected compiler failure", output)
        for line in success_lines:
            self.assertNotIn(line, output, f"success printed after compiler failure:\n{output}")

    def test_each_required_target_fails_when_compiler_fails(self) -> None:
        for target, (triple, _prefix, success) in REQUIRED_TARGETS.items():
            with self.subTest(target=target):
                result, calls = self.run_make(target, fail_targets="all")
                self.assertEqual(len(calls), 1, calls)
                self.assertIn(f"-Dtarget={triple}", calls[0].split())
                self.assert_failed_without_success(result, [success])

    def test_aggregate_fails_when_only_a_macos_compile_fails(self) -> None:
        for target in ("cross-macos-x86_64", "cross-macos-arm64"):
            triple = REQUIRED_TARGETS[target][0]
            with self.subTest(target=target):
                result, _calls = self.run_make("cross-compile-required", fail_targets=triple)
                self.assert_failed_without_success(result, [REQUIRED_TARGETS[target][2], AGGREGATE_SUCCESS])

    def test_macos_cross_from_other_mac_arch_propagates_failure(self) -> None:
        cases = {"cross-macos-x86_64": "arm64", "cross-macos-arm64": "x86_64"}
        for target, machine in cases.items():
            with self.subTest(target=target):
                result, calls = self.run_make(target, fail_targets="all", uname=("Darwin", machine))
                self.assertEqual(len(calls), 1, calls)
                self.assert_failed_without_success(result, [REQUIRED_TARGETS[target][2]])

    def test_positive_control_every_target_and_aggregate_succeed(self) -> None:
        for target, (triple, prefix, success) in REQUIRED_TARGETS.items():
            with self.subTest(target=target):
                result, calls = self.run_make(target)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(success, result.stdout)
                self.assertEqual(calls, [f"build -Dtarget={triple} -p {prefix} {ZIG_FLAGS}"])
        result, calls = self.run_make("cross-compile-required")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(AGGREGATE_SUCCESS, result.stdout)
        self.assertEqual(
            calls,
            [f"build -Dtarget={t} -p {p} {ZIG_FLAGS}" for t, p, _s in REQUIRED_TARGETS.values()],
        )

    def test_native_macos_skip_does_not_invoke_compiler(self) -> None:
        cases = {
            "cross-macos-x86_64": ("x86_64", "Skipping macOS x86_64 cross-compile on x86_64 macOS"),
            "cross-macos-arm64": ("arm64", "Skipping macOS ARM64 cross-compile on ARM64 macOS"),
        }
        for target, (machine, skip_line) in cases.items():
            with self.subTest(target=target):
                result, calls = self.run_make(target, fail_targets="all", uname=("Darwin", machine))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn(skip_line, result.stdout)
                self.assertNotIn(REQUIRED_TARGETS[target][2], result.stdout)
                self.assertEqual(calls, [])


class CrossCompileHookStatusTests(unittest.TestCase):
    """The configured pre-push hook command propagates make's status."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.stub_dir = pathlib.Path(self._tmp.name)
        _write_exec(self.stub_dir / "make", STUB_MAKE)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def run_hook(self, status: int):
        env = _base_env(self.stub_dir)
        env["STUB_MAKE_STATUS"] = str(status)
        return subprocess.run(hook_argv(), cwd=REPO_ROOT, capture_output=True, text=True, env=env, timeout=60)

    def assert_last_lines_kept(self, result) -> None:
        lines = result.stdout.splitlines()
        self.assertEqual(lines[-1], "stub-make argv: cross-compile-required")
        self.assertEqual(len(lines), 20, result.stdout)
        self.assertNotIn("stub-make line 1\n", result.stdout)
        self.assertIn("stub-make line 30", result.stdout)

    def test_hook_fails_when_make_fails(self) -> None:
        result = self.run_hook(MAKE_FAILURE_STATUS)
        self.assertEqual(result.returncode, MAKE_FAILURE_STATUS, result.stdout + result.stderr)
        self.assert_last_lines_kept(result)

    def test_positive_control_hook_succeeds_when_make_succeeds(self) -> None:
        result = self.run_hook(0)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_last_lines_kept(result)


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False, verbosity=2).result.wasSuccessful() else 1)
