"""Keep all required Debug shards while bounding their shared runner demand."""

import json
import re
import unittest
from collections import Counter
from pathlib import Path


class UnitCapacityTests(unittest.TestCase):
    def test_all_shards_share_four_slots_across_pipelines(self):
        text = (Path(__file__).resolve().parents[2] / ".gitlab-ci.yml").read_text()
        # This is a contract for our explicit matrix form, not a YAML parser.
        # GitLab CI lint validates the complete document. Keep this guard
        # runnable in the governance job's stock Python slim image.
        match = re.search(
            r"^test-zig-unit:\n(.*?)(?=^[A-Za-z_.][\w.-]*:\s*$|\Z)",
            text,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(match, "missing explicit Debug job")
        job = match.group(1)
        slots = {}
        shards = []
        for indexes, slot in re.findall(
            r'^      - TEST_SHARD_INDEX: (\[[^\n]+\])\n        TEST_SLOT: ("[^"\n]+")$',
            job,
            re.MULTILINE,
        ):
            indexes, slot = json.loads(indexes), json.loads(slot)
            shards.extend(indexes)
            slots.setdefault(slot, []).extend(indexes)
        self.assertEqual(Counter(shards), Counter(str(i) for i in range(16)))
        # SONNY-2772: 16 shards (a doubled aggregate) over four slots.
        self.assertEqual(len(slots), 4)
        self.assertEqual(sorted(map(len, slots.values())), [4, 4, 4, 4])
        self.assertRegex(job, r'(?m)^    TEST_SHARD_TOTAL: "16"$')
        self.assertRegex(job, r'(?m)^    ZIG_BUILD_JOBS: "1"$')
        self.assertIn("-- zig build -j${ZIG_BUILD_JOBS} test ", job)
        # A pipeline/ref/shard suffix here would defeat the shared capacity cap.
        self.assertRegex(job, r'(?m)^  resource_group: "test-zig-unit-slot-\$TEST_SLOT"$')
        self.assertRegex(job, r"(?m)^  tags: \[company, k8s, linux\]$")
        self.assertIn(
            "    - if: '$CI_PIPELINE_SOURCE == \"merge_request_event\"'\n      allow_failure: false",
            job,
        )
        self.assertIn("workflow:\n  auto_cancel:\n    on_job_failure: all", text)


if __name__ == "__main__":
    unittest.main()
