import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

from zig_fail_fast import failed_step


WRAPPER = Path(__file__).with_name("zig_fail_fast.py")


class ZigFailFastTests(unittest.TestCase):
    def invoke(self, code, *args):
        return subprocess.run(
            [sys.executable, str(WRAPPER), *args, "--", sys.executable, "-u", "-c", code],
            capture_output=True, text=True, timeout=8,
        )

    def test_warnings_do_not_fail_or_hide_output(self):
        output = "test\n+- run tests/example.zig w\nwarning: expected diagnostic\nfailed command: example\n"
        result = self.invoke(f"print({output!r}, end='')")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout, output)

    def test_failure_kills_build_and_descendants_and_keeps_diagnostics(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker = Path(tmp) / "unwanted-work"
            log = Path(tmp) / "reports" / "zig.log"
            descendant = (
                "import signal,time,pathlib;signal.signal(signal.SIGTERM,signal.SIG_IGN);"
                f"time.sleep(4);pathlib.Path({str(marker)!r}).touch()"
            )
            code = (
                "import subprocess,sys,time;"
                f"subprocess.Popen([sys.executable,'-c',{descendant!r}]);"
                "time.sleep(.1);"
                "print('test\\n+- run tests/example.zig 21 pass, 1 fail (22 total)');"
                "print(\"error: 'example.test.failure' failed:\\n    full stack trace\");"
                "print('failed command: example', flush=True);time.sleep(30)"
            )
            start = time.monotonic()
            result = self.invoke(code, "--log", str(log))
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertLess(time.monotonic() - start, 4)
            self.assertIn("full stack trace", log.read_text())
            time.sleep(2)
            self.assertFalse(marker.exists(), "descendant survived cancellation")

    def test_nonzero_exit_is_preserved_without_a_zig_summary(self):
        self.assertEqual(self.invoke("import sys;sys.exit(17)").returncode, 17)

    def test_external_cancellation_reaches_children(self):
        code = "import time;print('started',flush=True);time.sleep(30)"
        process = subprocess.Popen(
            [sys.executable, str(WRAPPER), "--", sys.executable, "-u", "-c", code],
            stdout=subprocess.PIPE, text=True,
        )
        try:
            self.assertEqual(process.stdout.readline().strip(), "started")
            os.kill(process.pid, signal.SIGTERM)
            self.assertEqual(process.wait(timeout=5), 128 + signal.SIGTERM)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()

    def test_only_structured_failed_steps_trigger_cancellation(self):
        for summary in (
            "+- run test 0 pass, 1 crash (1 total)",
            "|  +- run test 2 pass (2 total); 1 leaks",
            "+- run test 1 pass (1 total); 2 error logs",
            "+- run test 0 pass, 1 timeout (1 total)",
            "+- compile test Debug native 2 errors",
            "   +- run test failure",
            "\x1b[31m+- run test 0 pass, 1 fail (1 total)\x1b[0m",
        ):
            with self.subTest(summary=summary):
                self.assertTrue(failed_step(summary))
        for output in ("+- run test w", "failed command: test", "expected 1 fail",
                       "error: an expected test diagnostic", "+- run test 2 pass (2 total)"):
            self.assertFalse(failed_step(output))


if __name__ == "__main__":
    unittest.main()
