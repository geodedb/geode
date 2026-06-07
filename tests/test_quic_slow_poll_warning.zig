const std = @import("std");
const quic = @import("transport/quic");

// CANARY: REQ=REQ-GQL-074; FEATURE="Network Transport"; ASPECT=SlowPollWarning; STATUS=TESTED; TEST=slow_poll_warning_fires_only_past_threshold_and_rate_limited; OWNER=wire; UPDATED=2026-06-07

test "slow-poll warning fires only past the threshold and is rate-limited" {
    // shouldWarnSlowPoll(cycle_ns, threshold_ns, last_warn_ns, now_ns, min_interval_ns)

    // cycle_ns (500) < threshold_ns (1000) → no warning
    try std.testing.expect(!quic.shouldWarnSlowPoll(500, 1_000, 0, 10_000, 5_000));

    // cycle_ns (2000) > threshold_ns (1000), elapsed (10000 - 0 = 10000) >= min_interval (5000) → warn
    try std.testing.expect(quic.shouldWarnSlowPoll(2_000, 1_000, 0, 10_000, 5_000));

    // cycle_ns (2000) > threshold_ns (1000), elapsed (10000 - 9000 = 1000) < min_interval (5000) → rate-limited, no warn
    try std.testing.expect(!quic.shouldWarnSlowPoll(2_000, 1_000, 9_000, 10_000, 5_000));

    // cycle_ns (2000) > threshold_ns (1000), elapsed (10000 - 1000 = 9000) >= min_interval (5000) → warn
    try std.testing.expect(quic.shouldWarnSlowPoll(2_000, 1_000, 1_000, 10_000, 5_000));
}
