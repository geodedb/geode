"""Keep all required Debug shards while bounding their shared runner demand."""

from collections import Counter
from pathlib import Path
import unittest

import yaml


class UnitCapacityTests(unittest.TestCase):
    def test_all_shards_share_two_slots_across_pipelines(self):
        config = yaml.safe_load(
            (Path(__file__).resolve().parents[2] / ".gitlab-ci.yml").read_text()
        )
        job = config["test-zig-unit"]
        slots = {}
        shards = []
        for entry in job["parallel"]["matrix"]:
            for index in entry["TEST_SHARD_INDEX"]:
                shards.append(index)
                slots.setdefault(entry["TEST_SLOT"], []).append(index)
        self.assertEqual(Counter(shards), Counter(str(i) for i in range(8)))
        self.assertEqual(len(slots), 2)
        self.assertEqual(sorted(map(len, slots.values())), [4, 4])
        self.assertEqual(job["variables"]["TEST_SHARD_TOTAL"], "8")
        # A pipeline/ref/shard suffix here would defeat the shared capacity cap.
        self.assertEqual(job["resource_group"], "test-zig-unit-slot-$TEST_SLOT")
        self.assertEqual(job["tags"], ["company", "k8s", "linux"])
        mr_rule = next(rule for rule in job["rules"] if rule.get("if") ==
                       '$CI_PIPELINE_SOURCE == "merge_request_event"')
        self.assertIs(mr_rule["allow_failure"], False)
        self.assertEqual(config["workflow"]["auto_cancel"]["on_job_failure"], "all")


if __name__ == "__main__":
    unittest.main()
