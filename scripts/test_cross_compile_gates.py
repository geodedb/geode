#!/usr/bin/env python3
"""Exercise the real required-build recipes and pre-push shell status contract."""

import os
import re
import shlex
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TARGETS = (
    "x86_64-linux",
    "aarch64-linux-gnu",
    "riscv64-linux-gnu",
    "x86_64-macos",
    "aarch64-macos",
)


class CrossCompileGateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="geode-cross-gate-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.calls = self.directory / "calls"
        self.make = shutil.which("make")
        self.assertIsNotNone(self.make, "GNU make is required for recipe regression tests")
        self.env = dict(os.environ)
        for key in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL", "GNUMAKEFLAGS"):
            self.env.pop(key, None)
        self.env.update(
            PATH=str(self.bin) + os.pathsep + self.env.get("PATH", ""),
            GEODE_GATE_CALLS=str(self.calls),
            GEODE_GATE_FAIL_TARGET="",
            GEODE_GATE_EXIT="0",
            GEODE_GATE_OS="Linux",
            GEODE_GATE_ARCH="x86_64",
        )
        self.write_command(
            "zig",
            'printf "%s\\n" "$*" >> "$GEODE_GATE_CALLS"\n'
            "for arg do\n"
            '  if [ "$arg" = "-Dtarget=$GEODE_GATE_FAIL_TARGET" ]; then\n'
            '    echo "injected compiler failure" >&2\n'
            "    exit 19\n"
            "  fi\n"
            "done\n",
        )
        self.write_command(
            "uname",
            'if [ "${1:-}" = "-m" ]; then\n  echo "$GEODE_GATE_ARCH"\nelse\n  echo "$GEODE_GATE_OS"\nfi\n',
        )

    def write_command(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o700)
        return path

    def run_recipe(self, target):
        return subprocess.run(
            [self.make, "--no-print-directory", target, f"ZIG={self.bin / 'zig'}", "ZIG_FLAGS="],
            cwd=ROOT,
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    def run_configured_hook(self):
        # Execute the committed hook entry and its actual shell body, rather
        # than a second implementation of the pipeline under test.
        block = (ROOT / ".pre-commit-config.yaml").read_text().split("  - id: cross-compile-check\n", 1)[1]
        block = block.split("\n  - id:", 1)[0]
        entry = re.search(r"(?m)^    entry: (.+)$", block)
        body = re.search(r"(?ms)^    - -c\n    - (.*?)\n    language:", block)
        self.assertIsNotNone(entry)
        self.assertIsNotNone(body)
        command = body[1]
        if command.startswith("|\n"):
            command = textwrap.dedent(command[2:])
        self.write_command(
            "make",
            'printf "%s\\n" "$*" >> "$GEODE_GATE_CALLS"\necho "injected make result" >&2\nexit "$GEODE_GATE_EXIT"\n',
        )
        return subprocess.run(
            [*shlex.split(entry[1]), "-c", command],
            cwd=ROOT,
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=20,
            check=False,
        )

    def test_pre_push_preserves_make_failure_through_tail(self):
        self.env["GEODE_GATE_EXIT"] = "17"
        result = self.run_configured_hook()
        self.assertEqual(result.returncode, 17, result.stdout)
        self.assertIn("injected make result", result.stdout)
        self.assertEqual(self.calls.read_text().splitlines(), ["cross-compile-required"])

    def test_pre_push_accepts_success(self):
        result = self.run_configured_hook()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.calls.read_text().splitlines(), ["cross-compile-required"])

    def test_every_required_target_failure_stops_make(self):
        for target in TARGETS:
            with self.subTest(target=target):
                self.calls.unlink(missing_ok=True)
                self.env["GEODE_GATE_FAIL_TARGET"] = target
                result = self.run_recipe("cross-compile-required")
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("injected compiler failure", result.stdout)
                calls = self.calls.read_text().splitlines()
                self.assertEqual(len(calls), TARGETS.index(target) + 1)
                self.assertIn(f"-Dtarget={target}", calls[-1])
                self.assertNotIn("All required cross-compilation targets built successfully", result.stdout)

    def test_success_builds_all_five_required_targets(self):
        result = self.run_recipe("cross-compile-required")
        self.assertEqual(result.returncode, 0, result.stdout)
        calls = self.calls.read_text().splitlines()
        self.assertEqual(len(calls), len(TARGETS))
        for target, call in zip(TARGETS, calls, strict=True):
            self.assertIn(f"-Dtarget={target}", call)

    def test_native_macos_skip_behavior_is_preserved(self):
        self.env["GEODE_GATE_OS"] = "Darwin"
        for architecture, recipe in (("x86_64", "cross-macos-x86_64"), ("arm64", "cross-macos-arm64")):
            with self.subTest(architecture=architecture):
                self.env["GEODE_GATE_ARCH"] = architecture
                result = self.run_recipe(recipe)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertIn("Skipping", result.stdout)
                self.assertFalse(self.calls.exists(), result.stdout)


if __name__ == "__main__":
    unittest.main()
