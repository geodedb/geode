## Client error tracking

- Updated Rust QUIC client to mirror the Python/Go protocol (newline-delimited HELLO/RUN_GQL/PULL on a persistent stream), added hostname resolution, and hardened timeouts/retries. Basic spec now passes fully via `python3 clients/test-harness/run_tests.py --clients rust --spec specs/basic.yaml`.
- Trimmed the test harness to stop restarting the server between clients (cuts timeouts) while keeping per-test isolation logic unchanged.
- Zig client work-in-progress: new `zig_runner_new.zig` and `geode_client_v2.zig` build and connect, but the server never sends a HELLO or query response. QUIC traces show 1-RTT packets being sent with zero-length DCIDs and no inbound stream data; HELLO recv times out and every query hit the harness timeout. Next steps: enforce a non-zero DCID length (or otherwise align vendor_quic’s short-header DCID handling with the server) and verify the server actually receives/responds on stream 0. Recent debug runs live in `/tmp/zig_run.log`.
- Comprehensive test suite not re-run yet because Zig remains blocked; expect Rust/Go/Python to run but Zig will still time out until the DCID/HELLO issue above is resolved.
