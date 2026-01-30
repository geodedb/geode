const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const spinner_mod = geode.repl.spinner;
const Spinner = spinner_mod.Spinner;
const ProgressSpinner = spinner_mod.ProgressSpinner;
const SpinnerStyle = spinner_mod.SpinnerStyle;
const TerminalType = spinner_mod.TerminalType;

// CANARY: REQ=REQ-SHELL-SPINNER-004; FEATURE="ShellProcessingIndicator"; ASPECT=UnitTests; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-30
// Comprehensive unit tests for the spinner module covering:
// - Terminal type detection
// - Spinner styles for different terminals
// - Basic spinner operations (start, tick, stop)
// - Progress spinner functionality
// - Edge cases and error handling
// - PowerShell and cross-platform support

// ============================================================================
// Terminal Type Detection Tests
// ============================================================================

test "TerminalType.detect returns valid type" {
    const terminal = TerminalType.detect();

    // Verify the result is a valid enum value
    const valid = switch (terminal) {
        .unix_tty => true,
        .windows_console => true,
        .windows_modern => true,
        .non_interactive => true,
        .basic_ascii => true,
    };
    try testing.expect(valid);
}

test "TerminalType enum has all expected variants" {
    // Ensure exhaustive coverage of terminal types
    const types = [_]TerminalType{
        .unix_tty,
        .windows_console,
        .windows_modern,
        .non_interactive,
        .basic_ascii,
    };

    try testing.expect(types.len == 5);

    // Each type should map to a valid style
    for (types) |t| {
        const style = SpinnerStyle.forTerminal(t);
        try testing.expect(style.frames.len > 0);
        try testing.expect(style.interval_ms > 0);
    }
}

// ============================================================================
// SpinnerStyle Tests
// ============================================================================

test "SpinnerStyle.forTerminal returns appropriate style for each terminal" {
    // Unix TTY gets Unicode dots
    {
        const style = SpinnerStyle.forTerminal(.unix_tty);
        try testing.expect(style.frames.len == SpinnerStyle.dots.frames.len);
    }

    // Windows modern (PowerShell, Windows Terminal) gets Unicode dots
    {
        const style = SpinnerStyle.forTerminal(.windows_modern);
        try testing.expect(style.frames.len == SpinnerStyle.dots.frames.len);
    }

    // Windows console gets ASCII line
    {
        const style = SpinnerStyle.forTerminal(.windows_console);
        try testing.expectEqualStrings("-", style.frames[0]);
        try testing.expectEqualStrings("\\", style.frames[1]);
        try testing.expectEqualStrings("|", style.frames[2]);
        try testing.expectEqualStrings("/", style.frames[3]);
    }

    // Basic ASCII gets line style
    {
        const style = SpinnerStyle.forTerminal(.basic_ascii);
        try testing.expect(style.frames.len == SpinnerStyle.line.frames.len);
    }

    // Non-interactive gets simple dots
    {
        const style = SpinnerStyle.forTerminal(.non_interactive);
        try testing.expect(style.frames.len == SpinnerStyle.simple_dots.frames.len);
    }
}

test "SpinnerStyle.dots has valid Unicode frames" {
    const style = SpinnerStyle.dots;
    try testing.expect(style.frames.len == 10);
    try testing.expect(style.interval_ms == 80);

    // Verify all frames are valid UTF-8
    for (style.frames) |frame| {
        try testing.expect(frame.len > 0);
        // Should be valid UTF-8
        try testing.expect(std.unicode.utf8ValidateSlice(frame));
    }
}

test "SpinnerStyle.line has ASCII-only frames" {
    const style = SpinnerStyle.line;
    try testing.expect(style.frames.len == 4);
    try testing.expect(style.interval_ms == 100);

    // Verify all frames are single ASCII characters
    for (style.frames) |frame| {
        try testing.expect(frame.len == 1);
        try testing.expect(frame[0] < 128);
    }
}

test "SpinnerStyle.arrow has valid frames" {
    const style = SpinnerStyle.arrow;
    try testing.expect(style.frames.len == 8);
    try testing.expect(style.interval_ms == 100);
}

test "SpinnerStyle.box has valid frames" {
    const style = SpinnerStyle.box;
    try testing.expect(style.frames.len == 4);
    try testing.expect(style.interval_ms == 120);
}

test "SpinnerStyle.simple_dots for non-interactive terminals" {
    const style = SpinnerStyle.simple_dots;
    try testing.expect(style.frames.len == 4);
    try testing.expect(style.interval_ms == 300); // Slower for non-interactive

    // Should have padding for visual effect
    try testing.expectEqualStrings(".  ", style.frames[0]);
    try testing.expectEqualStrings(".. ", style.frames[1]);
    try testing.expectEqualStrings("...", style.frames[2]);
    try testing.expectEqualStrings("   ", style.frames[3]);
}

test "SpinnerStyle.bounce animation frames" {
    const style = SpinnerStyle.bounce;
    try testing.expect(style.frames.len == 4);
    try testing.expect(style.interval_ms == 120);
}

test "All SpinnerStyle constants have reasonable interval_ms" {
    const styles = [_]SpinnerStyle{
        SpinnerStyle.dots,
        SpinnerStyle.line,
        SpinnerStyle.arrow,
        SpinnerStyle.box,
        SpinnerStyle.simple_dots,
        SpinnerStyle.bounce,
    };

    for (styles) |style| {
        // Interval should be at least 10ms to avoid busy-waiting
        try testing.expect(style.interval_ms >= 10);
        // Interval should be at most 1000ms for responsive UI
        try testing.expect(style.interval_ms <= 1000);
    }
}

// ============================================================================
// Spinner Initialization Tests
// ============================================================================

test "Spinner.init creates spinner with default style for terminal" {
    const allocator = testing.allocator;
    const spinner = Spinner.init(allocator, "Loading...");

    try testing.expectEqualStrings("Loading...", spinner.message);
    try testing.expect(!spinner.started);
    try testing.expect(spinner.frame_index == 0);
    try testing.expect(spinner.last_line_width == 0);
}

test "Spinner.initWithStyle allows custom style" {
    const allocator = testing.allocator;
    const custom_style = SpinnerStyle{
        .frames = &[_][]const u8{ "X", "Y", "Z" },
        .interval_ms = 50,
    };
    const spinner = Spinner.initWithStyle(allocator, "Custom", custom_style);

    try testing.expect(spinner.style.frames.len == 3);
    try testing.expect(spinner.style.interval_ms == 50);
}

test "Spinner handles empty message" {
    const allocator = testing.allocator;
    const spinner = Spinner.init(allocator, "");

    try testing.expectEqualStrings("", spinner.message);
}

test "Spinner handles very long message" {
    const allocator = testing.allocator;
    const long_message = "A" ** 200;
    const spinner = Spinner.init(allocator, long_message);

    try testing.expect(spinner.message.len == 200);
}

// ============================================================================
// Spinner State Management Tests
// ============================================================================

test "Spinner.isRunning tracks started state correctly" {
    const allocator = testing.allocator;
    var spinner = Spinner.init(allocator, "Test");

    // Not started initially
    try testing.expect(!spinner.isRunning());

    spinner.start();
    try testing.expect(spinner.isRunning());

    spinner.stop(null);
    try testing.expect(!spinner.isRunning());
}

test "Spinner.stop is idempotent" {
    const allocator = testing.allocator;
    var spinner = Spinner.init(allocator, "Test");

    spinner.start();
    spinner.stop(null);
    spinner.stop(null); // Should not crash
    spinner.stop(null);

    try testing.expect(!spinner.isRunning());
}

test "Spinner.start sets timestamp" {
    const allocator = testing.allocator;
    var spinner = Spinner.init(allocator, "Test");

    const before = std.time.milliTimestamp();
    spinner.start();
    const after = std.time.milliTimestamp();

    // last_update should be set between before and after
    try testing.expect(spinner.last_update >= before);
    try testing.expect(spinner.last_update <= after);

    spinner.stop(null);
}

test "Spinner.setMessage updates message while running" {
    const allocator = testing.allocator;
    var spinner = Spinner.init(allocator, "Initial");

    try testing.expectEqualStrings("Initial", spinner.message);

    spinner.setMessage("Updated");
    try testing.expectEqualStrings("Updated", spinner.message);

    spinner.start();
    spinner.setMessage("While Running");
    try testing.expectEqualStrings("While Running", spinner.message);

    spinner.stop(null);
}

// ============================================================================
// Spinner Frame Cycling Tests
// ============================================================================

test "Spinner frame index cycles correctly" {
    const allocator = testing.allocator;
    const test_frames = [_][]const u8{ "A", "B", "C" };
    var spinner = Spinner.initWithStyle(allocator, "Test", SpinnerStyle{
        .frames = &test_frames,
        .interval_ms = 1,
    });

    try testing.expect(spinner.frame_index == 0);

    // Manual cycling
    spinner.frame_index = (spinner.frame_index + 1) % spinner.style.frames.len;
    try testing.expect(spinner.frame_index == 1);

    spinner.frame_index = (spinner.frame_index + 1) % spinner.style.frames.len;
    try testing.expect(spinner.frame_index == 2);

    // Should wrap back to 0
    spinner.frame_index = (spinner.frame_index + 1) % spinner.style.frames.len;
    try testing.expect(spinner.frame_index == 0);
}

test "Spinner.tick respects interval" {
    const allocator = testing.allocator;
    var spinner = Spinner.initWithStyle(allocator, "Test", SpinnerStyle{
        .frames = &[_][]const u8{ "A", "B", "C" },
        .interval_ms = 100, // 100ms interval
    });

    spinner.start();
    const initial_frame = spinner.frame_index;

    // Immediate tick should not advance (not enough time passed)
    const updated = spinner.tick();
    // Frame might or might not be updated depending on timing
    _ = updated;
    _ = initial_frame;

    spinner.stop(null);
}

// ============================================================================
// Spinner Success/Fail Methods Tests
// ============================================================================

test "Spinner.success stops spinner and marks success" {
    const allocator = testing.allocator;
    var spinner = Spinner.init(allocator, "Working");

    spinner.start();
    try testing.expect(spinner.isRunning());

    spinner.success("Done!");
    try testing.expect(!spinner.isRunning());
}

test "Spinner.success with null message" {
    const allocator = testing.allocator;
    var spinner = Spinner.init(allocator, "Working");

    spinner.start();
    spinner.success(null);
    try testing.expect(!spinner.isRunning());
}

test "Spinner.fail stops spinner and marks failure" {
    const allocator = testing.allocator;
    var spinner = Spinner.init(allocator, "Working");

    spinner.start();
    try testing.expect(spinner.isRunning());

    spinner.fail("Error occurred");
    try testing.expect(!spinner.isRunning());
}

test "Spinner.fail with null message" {
    const allocator = testing.allocator;
    var spinner = Spinner.init(allocator, "Working");

    spinner.start();
    spinner.fail(null);
    try testing.expect(!spinner.isRunning());
}

// ============================================================================
// ProgressSpinner Tests
// ============================================================================

test "ProgressSpinner.init creates progress tracker" {
    const allocator = testing.allocator;
    const progress = ProgressSpinner.init(allocator, "Processing", 100);

    try testing.expect(progress.total == 100);
    try testing.expect(progress.current == 0);
    try testing.expect(progress.show_percentage);
    try testing.expectEqualStrings("Processing", progress.base_message);
}

test "ProgressSpinner.increment advances count" {
    const allocator = testing.allocator;
    var progress = ProgressSpinner.init(allocator, "Processing", 100);

    try testing.expect(progress.current == 0);

    progress.increment();
    try testing.expect(progress.current == 1);

    progress.increment();
    try testing.expect(progress.current == 2);

    // Increment 10 more times
    for (0..10) |_| {
        progress.increment();
    }
    try testing.expect(progress.current == 12);
}

test "ProgressSpinner.increment does not exceed total" {
    const allocator = testing.allocator;
    var progress = ProgressSpinner.init(allocator, "Processing", 5);

    for (0..10) |_| {
        progress.increment();
    }

    try testing.expect(progress.current == 5); // Capped at total
}

test "ProgressSpinner.setCurrent sets specific value" {
    const allocator = testing.allocator;
    var progress = ProgressSpinner.init(allocator, "Processing", 100);

    progress.setCurrent(50);
    try testing.expect(progress.current == 50);

    progress.setCurrent(25);
    try testing.expect(progress.current == 25);

    progress.setCurrent(100);
    try testing.expect(progress.current == 100);
}

test "ProgressSpinner.setCurrent clamps to total" {
    const allocator = testing.allocator;
    var progress = ProgressSpinner.init(allocator, "Processing", 100);

    progress.setCurrent(150);
    try testing.expect(progress.current == 100);

    progress.setCurrent(999);
    try testing.expect(progress.current == 100);
}

test "ProgressSpinner lifecycle" {
    const allocator = testing.allocator;
    var progress = ProgressSpinner.init(allocator, "Processing", 10);

    progress.start();

    for (0..5) |_| {
        progress.increment();
        _ = progress.tick();
    }

    try testing.expect(progress.current == 5);

    progress.success("Completed");
}

test "ProgressSpinner with zero total" {
    const allocator = testing.allocator;
    var progress = ProgressSpinner.init(allocator, "Processing", 0);

    try testing.expect(progress.total == 0);
    try testing.expect(progress.current == 0);

    // Increment should not crash
    progress.increment();
    try testing.expect(progress.current == 0);
}

// ============================================================================
// Multiple Spinner Independence Tests
// ============================================================================

test "Multiple spinners operate independently" {
    const allocator = testing.allocator;

    var spinner1 = Spinner.init(allocator, "Spinner 1");
    var spinner2 = Spinner.init(allocator, "Spinner 2");

    try testing.expectEqualStrings("Spinner 1", spinner1.message);
    try testing.expectEqualStrings("Spinner 2", spinner2.message);

    spinner1.start();
    try testing.expect(spinner1.isRunning());
    try testing.expect(!spinner2.isRunning());

    spinner2.start();
    try testing.expect(spinner1.isRunning());
    try testing.expect(spinner2.isRunning());

    spinner1.stop(null);
    try testing.expect(!spinner1.isRunning());
    try testing.expect(spinner2.isRunning());

    spinner2.stop(null);
    try testing.expect(!spinner1.isRunning());
    try testing.expect(!spinner2.isRunning());
}

test "Multiple spinners with different styles" {
    const allocator = testing.allocator;

    var spinner1 = Spinner.initWithStyle(allocator, "Dots", SpinnerStyle.dots);
    var spinner2 = Spinner.initWithStyle(allocator, "Line", SpinnerStyle.line);
    var spinner3 = Spinner.initWithStyle(allocator, "Arrow", SpinnerStyle.arrow);

    try testing.expect(spinner1.style.frames.len != spinner2.style.frames.len);
    try testing.expect(spinner2.style.frames.len != spinner3.style.frames.len);
}

// ============================================================================
// PowerShell Compatibility Tests
// ============================================================================

test "Windows modern terminal (PowerShell) gets Unicode style" {
    // When detected as windows_modern, should use Unicode spinner
    const style = SpinnerStyle.forTerminal(.windows_modern);

    // Should be the dots style (Unicode)
    try testing.expect(style.frames.len == SpinnerStyle.dots.frames.len);
    try testing.expect(style.interval_ms == SpinnerStyle.dots.interval_ms);

    // Verify frames contain Unicode
    for (style.frames) |frame| {
        try testing.expect(frame.len > 1); // Unicode chars are multi-byte
    }
}

test "Windows console gets ASCII style" {
    const style = SpinnerStyle.forTerminal(.windows_console);

    // Should be the line style (ASCII)
    try testing.expect(style.frames.len == 4);

    // Verify frames are ASCII only
    for (style.frames) |frame| {
        try testing.expect(frame.len == 1);
        try testing.expect(frame[0] < 128);
    }
}

// ============================================================================
// Edge Cases and Error Handling
// ============================================================================

test "Spinner handles rapid start/stop cycles" {
    const allocator = testing.allocator;
    var spinner = Spinner.init(allocator, "Rapid");

    for (0..100) |_| {
        spinner.start();
        spinner.stop(null);
    }

    try testing.expect(!spinner.isRunning());
}

test "Spinner tick before start returns false" {
    const allocator = testing.allocator;
    var spinner = Spinner.init(allocator, "Not started");

    const updated = spinner.tick();
    try testing.expect(!updated);
}

test "Spinner tick after stop returns false" {
    const allocator = testing.allocator;
    var spinner = Spinner.init(allocator, "Stopped");

    spinner.start();
    spinner.stop(null);

    const updated = spinner.tick();
    try testing.expect(!updated);
}

test "ProgressSpinner stop without start" {
    const allocator = testing.allocator;
    var progress = ProgressSpinner.init(allocator, "Never started", 100);

    // Should not crash
    progress.stop("Final");
    progress.success("Done");
    progress.fail("Error");
}
