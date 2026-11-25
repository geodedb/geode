#!/usr/bin/env bash
# GitHub Actions runner for one Zig build/test command (.github/workflows/ci.yml).
#
#   scripts/ci/gha_zig_step.sh <log> -- <command...>
#
# The command runs under scripts/ci/zig_fail_fast.py exactly as the GitLab
# jobs run it, but its full output goes to <log> instead of the job log: some
# suites log every Raft apply, which floods the runner and the log store. The
# job log gets the build summary and, on failure, the tail; the workflow keeps
# the gzipped logs as an artifact.
#
# Shared 4-vCPU GitHub runners occasionally miss a tight wall-clock assertion
# (tests/test_sonny6636_server_snapshot.zig heartbeat budget,
# tests/test_sonny_write_allowlist_r4_transport.zig 1 s "empty last chain").
# A failed command is therefore run once more (GEODE_GHA_RETRIES, default 1);
# Zig reuses every artifact the first attempt built. A pass on the retry emits
# a ::warning:: naming the steps that needed it, so flakes stay visible; a
# second failure fails the step. Compile errors are never retried.
set -uo pipefail

if [ "$#" -lt 3 ] || [ "$2" != "--" ]; then
  echo "usage: $0 <log> -- <command...>" >&2
  exit 2
fi
log=$1
shift 2
retries=${GEODE_GHA_RETRIES:-1}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
mkdir -p "$(dirname "$log")"

summary() {
  grep -E "^Build Summary|steps succeeded|tests passed|tests? (failed|leaked)|^error:|failed command:" "$1" | tail -40 || true
}

# Failed step lines (the same predicate zig_fail_fast.py stops on), one per line.
failed_steps() {
  python3 - "$1" "$here" <<'PY'
import sys
sys.path.insert(0, sys.argv[2])
from zig_fail_fast import ANSI, failed_step

seen = []
with open(sys.argv[1], errors="replace") as fh:
    for line in fh:
        if failed_step(line):
            step = ANSI.sub("", line).strip().lstrip("|+-\\ ").strip()
            if step not in seen:
                seen.append(step)
print("\n".join(seen[:10]))
PY
}

echo "+ $*"
attempt=1
first_failures=""
while :; do
  attempt_log=$log
  [ "$attempt" -gt 1 ] && attempt_log="${log%.log}.attempt${attempt}.log"
  start=$(date +%s)
  python3 "$here/zig_fail_fast.py" --log "$attempt_log" -- "$@" >/dev/null 2>&1
  rc=$?
  echo "attempt ${attempt}: exit ${rc} after $(( $(date +%s) - start ))s, $(wc -l < "$attempt_log" | tr -d ' ') log lines"
  summary "$attempt_log"
  if [ "$rc" -eq 0 ]; then
    if [ "$attempt" -gt 1 ]; then
      steps=$(printf '%s' "$first_failures" | paste -sd ';' -)
      echo "::warning title=Passed on retry::${GITHUB_JOB:-job} needed a retry; attempt 1 failed in: ${steps:-unknown step (see the attempt-1 log artifact)}"
    fi
    break
  fi
  failures=$(failed_steps "$attempt_log")
  echo "::group::last 400 lines of attempt ${attempt}"
  tail -400 "$attempt_log"
  echo "::endgroup::"
  # A compile error is deterministic: never retry it.
  if [ "$attempt" -gt "$retries" ] || printf '%s\n' "$failures" | grep -q '^compile '; then
    echo "::error title=Zig step failed::failed in: $(printf '%s' "$failures" | paste -sd ';' -)"
    break
  fi
  [ "$attempt" -eq 1 ] && first_failures=$failures
  echo "Retrying once: shared-runner timing flakes are retried, a second failure fails the job."
  attempt=$((attempt + 1))
done

# Keep a pristine copy of each attempt for the artifact; the job log has the summary.
for f in "$log" "${log%.log}".attempt*.log; do
  [ -f "$f" ] && gzip -f "$f"
done
exit "$rc"
