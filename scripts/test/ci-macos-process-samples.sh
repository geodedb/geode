#!/usr/bin/env bash
# Diagnostic branch only: identify a stalled native test without changing it.
set -eu
mkdir -p reports
sampled=" "
while true; do
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  snapshot="reports/macos-process-${stamp}.txt"
  # Restrict output to Zig test executables; omit unrelated process arguments.
  ps -axo pid,etime,time,command | awk '/[.]zig-cache\/o\/[[:xdigit:]]+\/test /' > "$snapshot"
  if [ -s "$snapshot" ]; then
    echo "Native test processes at ${stamp}:"
    cat "$snapshot"
    while read -r test_pid elapsed cpu command; do
      case "$sampled" in *" $test_pid "*) continue ;; esac
      # Sampling only tests alive for at least five minutes keeps overhead low.
      minutes=${elapsed%:*}
      case "$minutes" in *:*|*-*) ;; *) [ "$minutes" -ge 5 ] || continue ;; esac
      sampled="$sampled$test_pid "
      sample "$test_pid" 1 1 -file "reports/macos-process-sample-${test_pid}.txt" >/dev/null 2>&1 || true
      if [ -s "reports/macos-process-sample-${test_pid}.txt" ]; then
        echo "Captured stack for native test ${test_pid} (${elapsed} elapsed)."
        sed -n '1,90p' "reports/macos-process-sample-${test_pid}.txt"
      fi
    done < "$snapshot"
  fi
  sleep 60
done
