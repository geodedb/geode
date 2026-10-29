"""Keep every required Zig shard while bounding shared runner demand."""

from collections import Counter
import json
from pathlib import Path
import re
import unittest


class UnitCapacityTests(unittest.TestCase):
    def test_all_shards_share_two_slots_across_pipelines(self):
        text = (Path(__file__).resolve().parents[2] / ".gitlab-ci.yml").read_text()
        # This is a contract for our explicit matrix form, not a YAML parser.
        # GitLab CI lint validates the complete document. Keep this guard
        # runnable in the governance job's stock Python slim image.
        match = re.search(
            r"^test-zig-unit:\n(.*?)(?=^[A-Za-z_.][\w.-]*:\s*$|\Z)",
            text, re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(match, "missing explicit Debug job")
        job = match.group(1)
        slots = {}
        shards = []
        for indexes, slot in re.findall(
            r'^      - TEST_SHARD_INDEX: (\[[^\n]+\])\n        TEST_SLOT: ("[^"\n]+")$',
            job, re.MULTILINE,
        ):
            indexes, slot = json.loads(indexes), json.loads(slot)
            shards.extend(indexes)
            slots.setdefault(slot, []).extend(indexes)
        self.assertEqual(Counter(shards), Counter(str(i) for i in range(8)))
        self.assertEqual(len(slots), 2)
        self.assertEqual(sorted(map(len, slots.values())), [4, 4])
        self.assertRegex(job, r'(?m)^    TEST_SHARD_TOTAL: "8"$')
        # A pipeline/ref/shard suffix here would defeat the shared capacity cap.
        self.assertRegex(job, r'(?m)^  resource_group: "test-zig-unit-slot-\$TEST_SLOT"$')
        self.assertRegex(job, r'(?m)^  tags: \[company, k8s, linux\]$')
        self.assertIn(
            "    - if: '$CI_PIPELINE_SOURCE == \"merge_request_event\"'\n"
            "      allow_failure: false", job,
        )
        self.assertIn("workflow:\n  auto_cancel:\n    on_job_failure: all", text)

    def test_release_shards_share_the_existing_twelve_slots(self):
        text = (Path(__file__).resolve().parents[2] / ".gitlab-ci.yml").read_text()
        match = re.search(
            r"^test-zig-release-safe:\n(.*?)(?=^[A-Za-z_.][\w.-]*:\s*$|\Z)",
            text, re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(match, "missing required ReleaseSafe job")
        job = match.group(1)
        slots = {}
        shards = []
        for indexes, slot in re.findall(
            r'^      - TEST_SHARD_INDEX: (\[[^\n]+\])\n        TEST_SLOT: ("[^"\n]+")$',
            job, re.MULTILINE,
        ):
            indexes, slot = json.loads(indexes), json.loads(slot)
            shards.extend(indexes)
            slots.setdefault(slot, []).extend(indexes)
        self.assertEqual(Counter(shards), Counter(str(i) for i in range(24)))
        self.assertEqual(set(slots), {str(i) for i in range(12)})
        self.assertEqual(sorted(map(len, slots.values())), [2] * 12)
        self.assertRegex(job, r'(?m)^    TEST_SHARD_TOTAL: "24"$')
        # Preserve the old names: active twelve-shard pipelines must consume
        # the same slots, not a separate pool of another twelve workers.
        self.assertRegex(job, r'(?m)^  resource_group: "test-zig-release-safe-shard-\$TEST_SLOT"$')
        self.assertRegex(job, r'(?m)^  timeout: 6h$')
        self.assertRegex(job, r'(?m)^    ZIG_BUILD_JOBS: "1"$')
        self.assertIn('scripts/ci/zig_fail_fast.py --log ', job)
        self.assertIn(
            "    - if: '$CI_MERGE_REQUEST_ID'\n"
            "      allow_failure: false", job,
        )
        self.assertIn(
            'prefix: "geode-zig-release-safe-v3-${ZIG_VERSION}-${TEST_SHARD_TOTAL}-${TEST_SHARD_INDEX}"',
            job,
        )


if __name__ == "__main__":
    unittest.main()
