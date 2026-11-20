"""Linux jobs prefer the dedicated runners; Spot is only ever the overflow.

The runner fleet (devnw/infra/org components/devnw-runners): the OVH, AWS and
Azure dedicated hosts carry company, dedicated, linux, x86 and kvm; the AWS
Spot overflow runner carries company, dedicated, linux, x86 and aws-spot but
not kvm, and polls only every 45 s. A job tagged [company, dedicated, linux,
x86] is therefore taken by a dedicated host first and by Spot only while the
dedicated pool is saturated; adding kvm keeps a job off Spot entirely.
`aws-spot` is carried by the Spot runner alone, so requesting it pins a job
to Spot. test-zig-release-safe shards pinned that way lost the Docker daemon
on the 2-vCPU Spot workers four runs in a row (pipeline 3090620963).
"""

import re
import unittest
from pathlib import Path

CI = Path(__file__).resolve().parents[2] / ".gitlab-ci.yml"
DEDICATED = "[company, dedicated, linux, x86]"
KVM = "[company, dedicated, kvm, linux, x86]"
# Zig compile/test, benchmark and image-build jobs: never on a Spot worker.
HEAVY_JOBS = (
    "test-zig-unit",
    "test-zig-release-safe",
    "test-cross-build",
    "test-code-coverage",
    "test-gql-compliance",
    "test-perf-gates-enforced",
    "test-performance-benchmarks",
    "loadtest-regression",
    "bench-timeseries",
    "bench-query-path",
    "governance-match-ops-campaign",
    "zig-fips-test-0.16.0",
    "dev-image-build",
    "dev-image-build-fips",
)


def job_body(text, name):
    # The governance job runs this in a stock Python image without PyYAML;
    # GitLab CI lint validates the complete document.
    match = re.search(
        rf"^{re.escape(name)}:\n(.*?)(?=^[A-Za-z_.][\w.-]*:\s*$|\Z)",
        text,
        re.MULTILINE | re.DOTALL,
    )
    return match.group(1) if match else None


class RunnerTagTests(unittest.TestCase):
    def setUp(self):
        self.text = CI.read_text()

    def test_no_job_pins_the_spot_runner(self):
        requested = [
            line.strip() for line in self.text.splitlines() if not line.lstrip().startswith("#") and "aws-spot" in line
        ]
        self.assertEqual(requested, [])

    def test_anchors_name_the_dedicated_tag_sets(self):
        self.assertRegex(
            self.text,
            rf"(?m)^\.dedicated-kvm-tags: &kvm-tags {re.escape(KVM)}$",
        )
        default = job_body(self.text, "default")
        self.assertIsNotNone(default)
        self.assertRegex(default, rf"(?m)^  tags: &dedicated-tags {re.escape(DEDICATED)}$")

    def test_heavy_jobs_run_on_dedicated_hosts_only(self):
        for name in HEAVY_JOBS:
            with self.subTest(job=name):
                body = job_body(self.text, name)
                self.assertIsNotNone(body, f"missing job {name}")
                self.assertRegex(body, r"(?m)^  tags: \*kvm-tags$")


if __name__ == "__main__":
    unittest.main()
