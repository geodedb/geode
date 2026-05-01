#!/usr/bin/env python3
"""lint_ci_yaml_runner_tags.py — pre-commit hook that ensures every
GitLab CI job using `image: docker:` or `services: docker:dind` ALSO
tags `linux` (or inherits a default that does). Without this guard,
GitLab's runner picker can assign a docker-image job to a Windows
PowerShell runner that happens to share other tags
(`company,dedicated`), at which point the bash script fails with
PowerShell parser errors.

Exit codes:
  0 — every docker job has `linux` in its effective tag set.
  1 — at least one docker job is missing `linux`. The script prints
      the offending job names + line numbers.

Why this exists: pipeline #1009 (v0.5.2 tag) was 100% green through
tests but failed in build-release because the runner picker assigned
the job to a Windows PowerShell runner that also matched the
`company,dedicated` tags. PowerShell choked on the bash heredoc:

    At line:395 char:3
    + if [ -d "docker/zig-packages" ] && ls docker/zig-packages/...
    Missing '(' after 'if' in if statement.

The fix was to add `linux` to the tags list. This hook prevents the
same trap for any new docker-using job the team adds.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple

CI_YAML = Path(".gitlab-ci.yml")


def parse_yaml(text: str) -> Dict[str, Any]:
    """Parse via PyYAML if available; fall back to a tolerant degraded
    walker that just captures top-level job blocks."""
    try:
        import yaml  # type: ignore
        return yaml.safe_load(text) or {}
    except ImportError:
        return _shallow_parse(text)


def _shallow_parse(text: str) -> Dict[str, Any]:
    """Degraded parser: detect top-level keys (jobs) with body lines.
    Sufficient for `tags:`, `image:`, `services:` extraction. Each
    value is the raw multi-line string of the job body.
    """
    out: Dict[str, Any] = {}
    cur_name: Optional[str] = None
    cur_body: List[str] = []
    for line in text.splitlines():
        if re.match(r"^[A-Za-z_][A-Za-z0-9_-]*:\s*$", line):
            if cur_name is not None:
                out[cur_name] = "\n".join(cur_body)
            cur_name = line.split(":", 1)[0]
            cur_body = []
        elif cur_name is not None:
            cur_body.append(line)
    if cur_name is not None:
        out[cur_name] = "\n".join(cur_body)
    return out


def collect_tags(body: Any) -> Set[str]:
    """Return the set of `tags:` entries declared on a job body.
    Body may be a dict (when PyYAML is available) or a string
    (degraded mode)."""
    if isinstance(body, dict):
        tags = body.get("tags") or []
        return set(t for t in tags if isinstance(t, str))
    if isinstance(body, str):
        out: Set[str] = set()
        in_tags = False
        tag_indent: Optional[int] = None
        for line in body.splitlines():
            stripped = line.lstrip()
            indent = len(line) - len(stripped)
            if re.match(r"^tags\s*:\s*$", stripped):
                in_tags = True
                tag_indent = None
                continue
            if in_tags:
                if not stripped:
                    continue
                if stripped.startswith("- "):
                    if tag_indent is None:
                        tag_indent = indent
                    if indent == tag_indent:
                        out.add(stripped[2:].strip())
                        continue
                if not stripped.startswith("- ") and indent <= (tag_indent or 0):
                    in_tags = False
        return out
    return set()


def uses_docker(body: Any) -> bool:
    """Return True if the job body declares an image starting with
    `docker:` OR a services entry containing `docker:dind`."""
    if isinstance(body, dict):
        image = body.get("image")
        if isinstance(image, str) and image.startswith("docker:"):
            return True
        if isinstance(image, dict):
            name = image.get("name", "")
            if isinstance(name, str) and name.startswith("docker:"):
                return True
        services = body.get("services") or []
        for svc in services:
            if isinstance(svc, str) and "docker:dind" in svc:
                return True
            if isinstance(svc, dict):
                name = svc.get("name", "")
                if isinstance(name, str) and "docker:dind" in name:
                    return True
        return False
    if isinstance(body, str):
        if re.search(r"^\s*image\s*:\s*docker:", body, re.MULTILINE):
            return True
        if re.search(r"^\s*-\s*docker:dind", body, re.MULTILINE):
            return True
    return False


def find_line(text: str, job_name: str) -> int:
    for i, line in enumerate(text.splitlines(), start=1):
        if line.startswith(f"{job_name}:"):
            return i
    return 0


def main() -> int:
    if not CI_YAML.exists():
        return 0
    text = CI_YAML.read_text()
    parsed = parse_yaml(text)
    if not isinstance(parsed, dict):
        return 0

    default_tags = collect_tags(parsed.get("default") or {})

    offenders: List[Tuple[str, int, List[str]]] = []
    for name, body in parsed.items():
        if name == "default" or name.startswith("."):
            continue
        if not uses_docker(body):
            continue
        job_tags = collect_tags(body) or default_tags
        if "linux" not in job_tags:
            offenders.append((name, find_line(text, name), sorted(job_tags)))

    if offenders:
        print("\n✗ .gitlab-ci.yml jobs use docker:dind without `linux` tag:\n", file=sys.stderr)
        for name, line, tags in offenders:
            tags_str = ", ".join(tags) if tags else "(none — inherits default)"
            print(f"  {name} (line {line}): tags=[{tags_str}]", file=sys.stderr)
        print(
            "\n  Add `- linux` to each job's `tags:` list. Without it, GitLab's\n"
            "  runner picker can assign the job to a Windows PowerShell runner\n"
            "  that also matches `company,dedicated`, breaking the bash script.\n"
            "  Pipeline #1009 (v0.5.2) failed exactly this way in build-release.",
            file=sys.stderr,
        )
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
