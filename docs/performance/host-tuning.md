# Loadtest host tuning

The Go loadtest client emits this warning on every run:

    failed to sufficiently increase receive buffer size (was: 208 kiB,
    wanted: 7168 kiB, got: 416 kiB). See
    https://github.com/quic-go/quic-go/wiki/UDP-Buffer-Sizes for details.

Under-sized UDP receive buffers cause drops at high concurrency, which
inflates p95/p99 and hides perf wins. Fix before every formal perf-gate
run:

    sudo sysctl -w net.core.rmem_max=7340032
    sudo sysctl -w net.core.wmem_max=7340032

Or persist in `/etc/sysctl.d/99-geode-loadtest.conf`:

    net.core.rmem_max=7340032
    net.core.wmem_max=7340032

## Other hygiene

- Stop systemd `geode.service`: `sudo systemctl stop geode.service`.
  Background servers are the biggest source of variance.
- Pin CPU governor to `performance`:
  `sudo cpupower frequency-set -g performance`
- Disable turbo if you want stable numbers across thermal cycles (up to
  30% Go runtime variance on lothiriel is attributable to this):
  `echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo`
- Use a fresh data dir (`/tmp/geode-loadtest-data`) for every perf-gate
  run — persisted WAL/data from an earlier run contaminates the result.

## CI host note

The `.gitlab-ci.yml:loadtest-regression` job runs these sysctls as its
first step (see Task M3.2). The runner user is in `sudoers` for
`sysctl` only.
