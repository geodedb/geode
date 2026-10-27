#!/usr/bin/env bash
# Diagnostic branch only: identify a stalled native test without changing it.
set -eu
mkdir -p reports
while true; do
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  snapshot="reports/macos-process-${stamp}.txt"
  # Restrict output to Zig test executables; omit unrelated process arguments.
  ps -axo pid,etime,time,command | awk '/[.]zig-cache\/o\/[[:xdigit:]]+\/test /' > "$snapshot"
  if [ -s "$snapshot" ]; then
    echo "Native test processes at ${stamp}:"
    cat "$snapshot"
    while read -r test_pid elapsed cpu command; do
      # Sample long-lived tests at most once per ten minutes to show progress.
      minutes=${elapsed%:*}
      case "$minutes" in *:*|*-*) ;; *) [ "$minutes" -ge 5 ] || continue ;; esac
      now=$(date +%s)
      last_file="reports/macos-process-last-sample-${test_pid}"
      last=0
      [ ! -f "$last_file" ] || last=$(cat "$last_file")
      [ "$((now - last))" -ge 600 ] || continue
      printf '%s\n' "$now" > "$last_file"
      sample "$test_pid" 1 1 -file "reports/macos-process-sample-${test_pid}-${stamp}.txt" >/dev/null 2>&1 || true
      if [ -s "reports/macos-process-sample-${test_pid}-${stamp}.txt" ]; then
        echo "Captured stack for native test ${test_pid} (${elapsed} elapsed)."
        sed -n '1,90p' "reports/macos-process-sample-${test_pid}-${stamp}.txt"
      fi
    done < "$snapshot"
  fi
  sleep 60
done
