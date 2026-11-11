"""Pipelines start for merge requests, the default branch and tags only.

A push to a branch that is not the default branch must not start a pipeline,
whether or not a merge request is open for it: the merge request pipeline is
the one that tests that commit. Schedules and manual (web/API) runs are not
pushes and keep working.
"""

import re
import unittest
from pathlib import Path

DEFAULT_BRANCH = "main"


def workflow_rules():
    """Return the ordered (condition, when) pairs of the workflow block.

    This reads our explicit one-line `- if:` / `- when:` form, not YAML in
    general: the governance job runs in a stock Python image without PyYAML,
    and GitLab CI lint validates the complete document.
    """
    text = (Path(__file__).resolve().parents[2] / ".gitlab-ci.yml").read_text()
    match = re.search(
        r"^workflow:\n(.*?)(?=^[A-Za-z_.][\w.-]*:\s*$|\Z)",
        text,
        re.MULTILINE | re.DOTALL,
    )
    assert match, "missing workflow block"
    rules_text = match.group(1).split("  rules:\n", 1)[1]
    rules = []
    for item in re.split(r"^    - ", rules_text, flags=re.MULTILINE)[1:]:
        condition = re.match(r"if: '([^'\n]+)'", item)
        when = re.search(r"^(?:      )?when: (\w+)", item, re.MULTILINE)
        rules.append(
            (
                condition.group(1) if condition else None,
                when.group(1) if when else "on_success",
            )
        )
    return rules


def holds(condition, variables):
    """Evaluate the subset of rule expressions the workflow block uses."""
    for clause in condition.split(" && "):
        clause = clause.strip()
        compare = re.fullmatch(r'(\$\w+) (==|!=) ("[^"]*"|\$\w+)', clause)
        if compare:
            left = variables.get(compare.group(1)[1:])
            right = compare.group(3)
            right = right[1:-1] if right.startswith('"') else variables.get(right[1:])
            if (left == right) != (compare.group(2) == "=="):
                return False
        elif re.fullmatch(r"\$\w+", clause):
            if not variables.get(clause[1:]):
                return False
        else:
            raise AssertionError(f"unsupported workflow clause: {clause}")
    return True


def pipeline_starts(**variables):
    variables.setdefault("CI_DEFAULT_BRANCH", DEFAULT_BRANCH)
    for condition, when in workflow_rules():
        if condition is None or holds(condition, variables):
            return when != "never"
    return False


class WorkflowRuleTests(unittest.TestCase):
    def test_branch_push_without_merge_request_starts_nothing(self):
        self.assertFalse(
            pipeline_starts(
                CI_PIPELINE_SOURCE="push",
                CI_COMMIT_BRANCH="fix/some-branch",
            )
        )

    def test_branch_push_with_open_merge_request_starts_nothing(self):
        self.assertFalse(
            pipeline_starts(
                CI_PIPELINE_SOURCE="push",
                CI_COMMIT_BRANCH="fix/some-branch",
                CI_OPEN_MERGE_REQUESTS="devnw/codepros/geode/geode!1",
            )
        )

    def test_merge_request_event_starts_a_pipeline(self):
        self.assertTrue(
            pipeline_starts(
                CI_PIPELINE_SOURCE="merge_request_event",
                CI_MERGE_REQUEST_SOURCE_BRANCH_NAME="fix/some-branch",
            )
        )

    def test_default_branch_push_starts_a_pipeline(self):
        self.assertTrue(
            pipeline_starts(
                CI_PIPELINE_SOURCE="push",
                CI_COMMIT_BRANCH=DEFAULT_BRANCH,
            )
        )

    def test_tag_push_starts_a_pipeline(self):
        self.assertTrue(
            pipeline_starts(
                CI_PIPELINE_SOURCE="push",
                CI_COMMIT_TAG="v0.8.24",
            )
        )

    def test_schedule_and_manual_runs_still_start(self):
        for source in ("schedule", "web", "api"):
            with self.subTest(source=source):
                self.assertTrue(
                    pipeline_starts(
                        CI_PIPELINE_SOURCE=source,
                        CI_COMMIT_BRANCH=DEFAULT_BRANCH,
                    )
                )


if __name__ == "__main__":
    unittest.main()
