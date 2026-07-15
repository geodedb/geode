#!/usr/bin/env python3
"""lint_ci_yaml_docker_names.py — pre-commit hook that validates every
docker container name assigned in .gitlab-ci.yml scripts.

Why this exists: pipeline #1508's `snapshot` job died at
`docker create --name _fipsprov ...` with
`Invalid container name (_fipsprov)` — Docker requires container names
to match [a-zA-Z0-9][a-zA-Z0-9_.-]*, i.e. the FIRST character must be
alphanumeric. The same trap recurs for any name that begins with an
underscore/dash OR with a shell variable that can expand empty
(`--name "${PREFIX}_x"` → `_x`).

Rules enforced on every `--name <value>` inside the CI YAML:
  1. After stripping quotes, the name must start with [a-zA-Z0-9].
  2. A name may not START with a variable reference ($VAR / ${VAR});
     prefix it with a literal instead (e.g. "fipsprov-${CI_JOB_ID}").
  3. Literal characters must stay within [a-zA-Z0-9_.-].

Exit codes: 0 clean, 1 violations (printed with line numbers).
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

CI_YAML = Path(".gitlab-ci.yml")

NAME_FLAG_RE = re.compile(r"--name[= ]+(\"[^\"]*\"|'[^']*'|\S+)")
VALID_LITERAL_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_.\-]*$")


def check_name(raw: str) -> str | None:
    """Return an error string when the container name is invalid."""
    name = raw.strip("\"'")
    if not name:
        return "empty container name"
    if name.startswith(("$",)):
        return (
            f"name {name!r} starts with a variable that can expand empty — "
            'prefix with a literal (e.g. "fipsprov-${CI_JOB_ID}")'
        )
    if not re.match(r"[a-zA-Z0-9]", name):
        return f"name {name!r} must start with [a-zA-Z0-9] (docker requirement)"
    # Validate the literal portion before any variable reference.
    literal = name.split("$", 1)[0]
    stripped = literal.rstrip("_.-")  # separators before a var are fine
    if stripped and not VALID_LITERAL_RE.match(literal.rstrip("_.-") or literal[:1]):
        return f"name {name!r} contains characters outside [a-zA-Z0-9_.-]"
    return None


def main() -> int:
    if not CI_YAML.is_file():
        return 0
    violations: list[str] = []
    for lineno, line in enumerate(CI_YAML.read_text(encoding="utf-8").splitlines(), 1):
        if "docker" not in line or "--name" not in line:
            continue
        for match in NAME_FLAG_RE.finditer(line):
            error = check_name(match.group(1))
            if error:
                violations.append(f"  .gitlab-ci.yml:{lineno}: {error}")
    if violations:
        print("✗ invalid docker container name(s) in .gitlab-ci.yml:")
        print("\n".join(violations))
        return 1
    print("lint-ci-yaml-docker-names: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
