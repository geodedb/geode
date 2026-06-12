#!/usr/bin/env python3
"""CI migration guard for .gql migration files (GAP-0882 / SEC-MIG-02).

Lints GQL migration files without requiring a running geode server:

1. File sanity      - readable, valid UTF-8, not binary.
2. Lexical checks   - balanced (), {}, [] and terminated strings/block
                      comments (scanned outside strings/comments).
3. Destructive policy - any statement containing a destructive keyword
                      (DROP, DELETE, DETACH DELETE, TRUNCATE) outside
                      strings/comments requires an explicit guard comment
                      in the same file:

                          -- destructive: acknowledged
                      or  // destructive: acknowledged

Rationale: the geode binary has no offline parse-only mode (``geode
migrate run --dry-run`` still needs a QUIC server), so this guard is a
standalone lexer-level lint. It is intentionally conservative: it never
executes migration content and fails closed on undecodable files.

Usage:
    check_migrations.py [files...]      lint the given .gql files
    check_migrations.py                 lint all migrations/**/*.gql
    check_migrations.py --self-test     run built-in fixture tests
"""

from __future__ import annotations

import pathlib
import re
import sys
import tempfile

DESTRUCTIVE_KEYWORDS = ("DROP", "DELETE", "TRUNCATE")
GUARD_MARKER = "destructive: acknowledged"
DEFAULT_GLOB = "migrations/**/*.gql"


def strip_strings_and_comments(text: str) -> tuple[str, list[str], list[str]]:
    """Return (code, comments, errors).

    ``code`` is the input with string literals and comments replaced by
    spaces (newlines preserved so line numbers survive). ``comments``
    collects comment bodies for guard-marker detection. ``errors``
    collects unterminated string/comment findings.
    """
    code: list[str] = []
    comments: list[str] = []
    errors: list[str] = []
    i = 0
    n = len(text)
    line = 1

    while i < n:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if ch == "\n":
            line += 1
        # Line comments: -- or //
        if (ch == "-" and nxt == "-") or (ch == "/" and nxt == "/"):
            end = text.find("\n", i)
            if end == -1:
                end = n
            comments.append(text[i:end])
            code.append(" " * (end - i))
            i = end
            continue
        # Block comment: /* ... */
        if ch == "/" and nxt == "*":
            end = text.find("*/", i + 2)
            if end == -1:
                errors.append(f"line {line}: unterminated block comment")
                comments.append(text[i:])
                code.append(" " * (n - i))
                i = n
                continue
            body = text[i : end + 2]
            comments.append(body)
            line += body.count("\n")
            code.append(re.sub(r"[^\n]", " ", body))
            i = end + 2
            continue
        # String literals: ' or " (GQL escapes by doubling or backslash)
        if ch in ("'", '"'):
            quote = ch
            j = i + 1
            terminated = False
            while j < n:
                c = text[j]
                if c == "\\" and j + 1 < n:
                    j += 2
                    continue
                if c == quote:
                    if j + 1 < n and text[j + 1] == quote:  # doubled quote
                        j += 2
                        continue
                    terminated = True
                    break
                if c == "\n":
                    break  # strings do not span lines in migration GQL
                j += 1
            if not terminated:
                errors.append(f"line {line}: unterminated string literal")
                end = j
            else:
                end = j + 1
            body = text[i:end]
            line += body.count("\n")
            code.append(re.sub(r"[^\n]", " ", body))
            i = end
            continue
        code.append(ch)
        i += 1
    return "".join(code), comments, errors


def check_balance(code: str) -> list[str]:
    """Check (), {}, [] balance on comment/string-stripped code."""
    pairs = {")": "(", "}": "{", "]": "["}
    stack: list[tuple[str, int]] = []
    errors: list[str] = []
    line = 1
    for ch in code:
        if ch == "\n":
            line += 1
        elif ch in "({[":
            stack.append((ch, line))
        elif ch in ")}]":
            if not stack or stack[-1][0] != pairs[ch]:
                errors.append(f"line {line}: unbalanced '{ch}'")
                # keep scanning; pop if mismatched-but-nonempty to limit noise
                if stack:
                    stack.pop()
            else:
                stack.pop()
    for opener, oline in stack:
        errors.append(f"line {oline}: unclosed '{opener}'")
    return errors


def find_destructive(code: str) -> list[str]:
    """Return findings for destructive keywords outside strings/comments."""
    findings: list[str] = []
    for kw in DESTRUCTIVE_KEYWORDS:
        for m in re.finditer(rf"\b{kw}\b", code, flags=re.IGNORECASE):
            line = code.count("\n", 0, m.start()) + 1
            findings.append(f"line {line}: destructive statement keyword '{kw}'")
    return findings


def lint_file(path: pathlib.Path) -> list[str]:
    """Lint one migration file; return a list of error strings."""
    try:
        raw = path.read_bytes()
    except OSError as exc:
        return [f"unreadable: {exc}"]
    if b"\x00" in raw:
        return ["binary content (NUL byte) in migration file"]
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        return [f"not valid UTF-8: {exc}"]

    code, comments, errors = strip_strings_and_comments(text)
    errors.extend(check_balance(code))

    destructive = find_destructive(code)
    if destructive:
        acknowledged = any(GUARD_MARKER in c.lower().replace("　", " ") for c in comments)
        if not acknowledged:
            errors.extend(destructive)
            errors.append(f"destructive statements require a guard comment: '-- {GUARD_MARKER}' (policy: SEC-MIG-02)")
    return errors


def discover_default(root: pathlib.Path) -> list[pathlib.Path]:
    return sorted(root.glob(DEFAULT_GLOB))


def run(paths: list[pathlib.Path]) -> int:
    if not paths:
        print("No .gql migration files to check.")
        return 0
    failed = 0
    for path in paths:
        errors = lint_file(path)
        if errors:
            failed += 1
            print(f"FAIL {path}")
            for err in errors:
                print(f"  - {err}")
        else:
            print(f"OK   {path}")
    if failed:
        print(f"\n{failed}/{len(paths)} migration file(s) failed the guard.")
        return 1
    print(f"\nAll {len(paths)} migration file(s) passed the guard.")
    return 0


# ---------------------------------------------------------------------------
# Self-test fixtures
# ---------------------------------------------------------------------------

_FIXTURES: list[tuple[str, str, bool]] = [
    (
        "clean_create.gql",
        "-- Migration: add nodes\nCREATE (:User {name: 'alice'});\n",
        True,
    ),
    (
        "comment_only_template.gql",
        "-- Migration: add_indexes\n-- Add your GQL statements here\n",
        True,
    ),
    (
        "drop_unacknowledged.gql",
        "CREATE GRAPH g;\nDROP GRAPH old_graph;\n",
        False,
    ),
    (
        "drop_acknowledged.gql",
        "-- destructive: acknowledged\nDROP GRAPH old_graph;\n",
        True,
    ),
    (
        "delete_acknowledged_slash.gql",
        "// destructive: acknowledged -- cleans stale rels\nMATCH ()-[r:OLD]->() DELETE r;\n",
        True,
    ),
    (
        "delete_in_string_ok.gql",
        "CREATE (:Audit {action: 'DELETE'});\n",
        True,
    ),
    (
        "delete_in_comment_ok.gql",
        "-- this migration does not DELETE anything\nCREATE (:N);\n",
        True,
    ),
    (
        "deleted_at_property_ok.gql",
        "CREATE (:User {deleted_at: null});\n",
        True,
    ),
    (
        "unbalanced_paren.gql",
        "CREATE (:User {name: 'x'};\n",
        False,
    ),
    (
        "unterminated_string.gql",
        "CREATE (:User {name: 'oops});\n",
        False,
    ),
    (
        "detach_delete_unacknowledged.gql",
        "MATCH (n:Tmp) DETACH DELETE n;\n",
        False,
    ),
]


def self_test() -> int:
    failures = 0
    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = pathlib.Path(tmp)
        for name, content, expect_pass in _FIXTURES:
            p = tmpdir / name
            p.write_text(content, encoding="utf-8")
            errors = lint_file(p)
            passed = not errors
            ok = passed == expect_pass
            status = "ok" if ok else "FAILED"
            expectation = "pass" if expect_pass else "fail"
            print(f"self-test {status}: {name} (expected {expectation})")
            if not ok:
                failures += 1
                for err in errors:
                    print(f"    - {err}")
    if failures:
        print(f"\nself-test: {failures}/{len(_FIXTURES)} fixture(s) FAILED")
        return 1
    print(f"\nself-test: all {len(_FIXTURES)} fixtures passed")
    return 0


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        return self_test()
    if argv:
        paths = [pathlib.Path(a) for a in argv]
        missing = [p for p in paths if not p.is_file()]
        if missing:
            for p in missing:
                print(f"FAIL {p}\n  - file not found")
            return 1
    else:
        paths = discover_default(pathlib.Path.cwd())
    return run(paths)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
