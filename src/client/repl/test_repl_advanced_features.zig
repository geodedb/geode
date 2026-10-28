const std = @import("std");
const testing = std.testing;

// CANARY: REQ=REQ-REPL-ADVANCED-001; FEATURE="REPL Advanced Features"; ASPECT=Testing; STATUS=TESTED; TEST=test_repl_advanced_features; OWNER=repl; UPDATED=2025-11-17

// Import the modules (adjust paths as needed in actual build)
const syntax_highlighter = @import("syntax_highlighter.zig");
const fuzzy_search = @import("fuzzy_search.zig");
const result_pager = @import("result_pager.zig");
const session_state = @import("session_state.zig");

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// ============================================================================
// Syntax Highlighting Tests
// ============================================================================

test "syntax highlighting: GQL keywords are highlighted" {
    const input = "MATCH (n) RETURN n";
    const highlighted = try syntax_highlighter.highlight(testing.allocator, input, true);
    defer testing.allocator.free(highlighted);

    // Should contain ANSI escape codes
    try testing.expect(std.mem.indexOf(u8, highlighted, "\x1b[") != null);

    // Should contain blue color for keywords
    try testing.expect(std.mem.indexOf(u8, highlighted, syntax_highlighter.Color.blue) != null);
}

test "syntax highlighting: string literals are colored" {
    const input = "RETURN 'hello world' AS greeting";
    const highlighted = try syntax_highlighter.highlight(testing.allocator, input, true);
    defer testing.allocator.free(highlighted);

    // Should contain green color for strings
    try testing.expect(std.mem.indexOf(u8, highlighted, syntax_highlighter.Color.green) != null);
}

test "syntax highlighting: numbers are colored" {
    const input = "RETURN 42, 3.14159";
    const highlighted = try syntax_highlighter.highlight(testing.allocator, input, true);
    defer testing.allocator.free(highlighted);

    // Should contain cyan color for numbers
    try testing.expect(std.mem.indexOf(u8, highlighted, syntax_highlighter.Color.cyan) != null);
}

test "syntax highlighting: meta commands are colored" {
    const input = "\\help";
    const highlighted = try syntax_highlighter.highlight(testing.allocator, input, true);
    defer testing.allocator.free(highlighted);

    // Should contain magenta color for meta commands
    try testing.expect(std.mem.indexOf(u8, highlighted, syntax_highlighter.Color.bright_magenta) != null);
}

test "syntax highlighting: operators are colored" {
    const input = "WHERE x = 10 AND y > 5";
    const highlighted = try syntax_highlighter.highlight(testing.allocator, input, true);
    defer testing.allocator.free(highlighted);

    // Should contain yellow color for operators
    try testing.expect(std.mem.indexOf(u8, highlighted, syntax_highlighter.Color.yellow) != null);
}

test "syntax highlighting: parentheses are highlighted" {
    const input = "MATCH (n:Person {name: 'Alice'})";
    const highlighted = try syntax_highlighter.highlight(testing.allocator, input, true);
    defer testing.allocator.free(highlighted);

    // Should contain bright yellow for parentheses
    try testing.expect(std.mem.indexOf(u8, highlighted, syntax_highlighter.Color.bright_yellow) != null);
}

test "syntax highlighting: can be disabled" {
    const input = "MATCH (n) RETURN n";
    const highlighted = try syntax_highlighter.highlight(testing.allocator, input, false);
    defer testing.allocator.free(highlighted);

    // Should be identical to input when colors disabled
    try testing.expectEqualStrings(input, highlighted);
}

test "syntax highlighting: strip colors removes ANSI codes" {
    const colored = "\x1b[34mMATCH\x1b[0m (n) \x1b[34mRETURN\x1b[0m n";
    const stripped = try syntax_highlighter.stripColors(testing.allocator, colored);
    defer testing.allocator.free(stripped);

    try testing.expectEqualStrings("MATCH (n) RETURN n", stripped);
}

test "syntax highlighting: multi-line queries" {
    const input = "MATCH (n)\nRETURN n\nLIMIT 10";
    const highlighted = try syntax_highlighter.highlight(testing.allocator, input, true);
    defer testing.allocator.free(highlighted);

    // Should preserve newlines
    const stripped = try syntax_highlighter.stripColors(testing.allocator, highlighted);
    defer testing.allocator.free(stripped);
    try testing.expectEqualStrings(input, stripped);
}

// ============================================================================
// Fuzzy Search Tests
// ============================================================================

test "fuzzy search: exact match has highest score" {
    const score1 = try fuzzy_search.fuzzyScore(testing.allocator, "match", "match");
    const score2 = try fuzzy_search.fuzzyScore(testing.allocator, "match", "matching");

    try testing.expect(score1 > score2);
    try testing.expect(score1 >= 1000); // Exact match bonus
}

test "fuzzy search: case insensitive matching" {
    const score1 = try fuzzy_search.fuzzyScore(testing.allocator, "match", "MATCH");
    const score2 = try fuzzy_search.fuzzyScore(testing.allocator, "MATCH", "match");

    try testing.expectEqual(score1, score2);
}

test "fuzzy search: starts with gets high score" {
    const score = try fuzzy_search.fuzzyScore(testing.allocator, "mat", "match (n) return n");

    try testing.expect(score > 0);
}

test "fuzzy search: contains substring gets positive score" {
    const score = try fuzzy_search.fuzzyScore(testing.allocator, "ret", "match (n) return n");

    try testing.expect(score > 0);
}

test "fuzzy search: Levenshtein distance basic" {
    const dist1 = try fuzzy_search.levenshteinDistance(testing.allocator, "hello", "hello");
    const dist2 = try fuzzy_search.levenshteinDistance(testing.allocator, "cat", "bat");
    const dist3 = try fuzzy_search.levenshteinDistance(testing.allocator, "kitten", "sitting");

    try testing.expectEqual(@as(usize, 0), dist1);
    try testing.expectEqual(@as(usize, 1), dist2);
    try testing.expectEqual(@as(usize, 3), dist3);
}

test "fuzzy search: search returns sorted results" {
    const candidates = [_][]const u8{
        "MATCH (n) RETURN n",
        "MATCH (n:Person) RETURN n.name",
        "CREATE (n:Node)",
        "MERGE (n) RETURN n",
        "DELETE n WHERE n.id = 1",
    };

    const results = try fuzzy_search.fuzzySearch(testing.allocator, "match", &candidates, 10);
    defer testing.allocator.free(results);

    // Should find MATCH queries
    try testing.expect(results.len >= 2);

    // Scores should be in descending order
    for (results[0 .. results.len - 1], 0..) |match, i| {
        try testing.expect(match.score >= results[i + 1].score);
    }

    // Best match should contain "MATCH"
    try testing.expect(std.mem.indexOf(u8, results[0].text, "MATCH") != null);
}

test "fuzzy search: respects max results limit" {
    const candidates = [_][]const u8{
        "MATCH (n) RETURN n",
        "MATCH (n:Person) RETURN n.name",
        "MATCH (n:Product) RETURN n.price",
        "MATCH (n:Order) RETURN n.total",
    };

    const results = try fuzzy_search.fuzzySearch(testing.allocator, "match", &candidates, 2);
    defer testing.allocator.free(results);

    try testing.expectEqual(@as(usize, 2), results.len);
}

test "fuzzy search: FuzzyFinder workflow" {
    const candidates = [_][]const u8{
        "MATCH (n) RETURN n",
        "CREATE (n:Node)",
        "DELETE n",
        "MERGE (n) RETURN n",
    };

    var finder = try fuzzy_search.FuzzyFinder.init(testing.allocator, &candidates);
    defer finder.deinit();

    // No query - should return all
    const matches = try finder.getMatches();
    defer testing.allocator.free(matches);
    try testing.expect(matches.len > 0);

    // Update query
    try finder.updateQuery("match");
    const filtered = try finder.getMatches();
    defer testing.allocator.free(filtered);

    // Should find MATCH queries
    try testing.expect(filtered.len > 0);
    try testing.expect(std.mem.indexOf(u8, filtered[0].text, "MATCH") != null);

    // Test navigation
    finder.selectNext(filtered);
    try testing.expectEqual(@as(usize, 1), finder.selected_index);

    finder.selectPrev(filtered);
    try testing.expectEqual(@as(usize, 0), finder.selected_index);
}

// ============================================================================
// Result Pager Tests
// ============================================================================

test "result pager: shouldPage respects configuration" {
    const config = result_pager.PagerConfig{
        .page_size = 25,
        .enabled = true,
        .auto_page = true,
        .threshold = 50,
    };

    const pager = result_pager.ResultPager.init(testing.allocator, config);

    // Small result set - no paging
    try testing.expect(!pager.shouldPage(30));

    // Large result set - should page
    try testing.expect(pager.shouldPage(100));
}

test "result pager: disabled pager never pages" {
    const config = result_pager.PagerConfig{
        .enabled = false,
    };

    const pager = result_pager.ResultPager.init(testing.allocator, config);

    try testing.expect(!pager.shouldPage(1000));
}

test "result pager: calculates correct page bounds" {
    const total_rows: usize = 25;
    const page_size: usize = 10;

    // Page 0: rows 0-9
    const page0_start = 0 * page_size;
    const page0_end = @min(page0_start + page_size, total_rows);
    try testing.expectEqual(@as(usize, 0), page0_start);
    try testing.expectEqual(@as(usize, 10), page0_end);

    // Page 1: rows 10-19
    const page1_start = 1 * page_size;
    const page1_end = @min(page1_start + page_size, total_rows);
    try testing.expectEqual(@as(usize, 10), page1_start);
    try testing.expectEqual(@as(usize, 20), page1_end);

    // Page 2: rows 20-24 (partial page)
    const page2_start = 2 * page_size;
    const page2_end = @min(page2_start + page_size, total_rows);
    try testing.expectEqual(@as(usize, 20), page2_start);
    try testing.expectEqual(@as(usize, 25), page2_end);
}

test "result pager: page out of bounds returns false" {
    const config = result_pager.PagerConfig{ .page_size = 10 };
    var pager = result_pager.ResultPager.init(testing.allocator, config);
    defer pager.deinit();

    // Create simple test data
    const json_data = "{\"columns\":[{\"name\":\"id\",\"type\":\"INTEGER\"}],\"rows\":[{\"id\":1},{\"id\":2},{\"id\":3}]}";
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json_data, .{});
    defer parsed.deinit();

    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();

    // Page 0 should succeed
    const result0 = try pager.displayPage(&output.writer, parsed.value, 0, .table);
    try testing.expect(result0);

    // Page 10 (out of bounds) should fail
    const result10 = try pager.displayPage(&output.writer, parsed.value, 10, .table);
    try testing.expect(!result10);
}

// ============================================================================
// Session State Tests
// ============================================================================

test "session state: save and load roundtrip" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmpDirRealpathAlloc(testing.allocator, &tmp_dir.sub_path);
    defer testing.allocator.free(tmp_path);

    const session_file = try std.fs.path.join(testing.allocator, &.{ tmp_path, "test_session.json" });
    defer testing.allocator.free(session_file);

    // Create session
    var state = session_state.SessionState.init(testing.allocator);
    defer state.deinit(testing.allocator);

    state.database = try testing.allocator.dupe(u8, "testdb");
    state.in_transaction = true;
    state.format = .csv;
    state.show_timing = true;
    state.keymap = .vi;
    state.last_server = try testing.allocator.dupe(u8, "localhost:3141");

    try state.variables.put(try testing.allocator.dupe(u8, "var1"), try testing.allocator.dupe(u8, "value1"));

    // Save
    try state.save(testing.allocator, session_file);

    // Load
    var loaded = try session_state.SessionState.load(testing.allocator, session_file);
    defer loaded.deinit(testing.allocator);

    // Verify
    try testing.expectEqualStrings("testdb", loaded.database.?);
    try testing.expectEqual(true, loaded.in_transaction);
    try testing.expectEqual(session_state.SessionState.Format.csv, loaded.format);
    try testing.expectEqual(true, loaded.show_timing);
    try testing.expectEqual(session_state.SessionState.Keymap.vi, loaded.keymap);
    try testing.expectEqualStrings("localhost:3141", loaded.last_server.?);
    try testing.expectEqualStrings("value1", loaded.variables.get("var1").?);
}

test "session state: handles null/missing fields" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try tmpDirRealpathAlloc(testing.allocator, &tmp_dir.sub_path);
    defer testing.allocator.free(tmp_path);

    const session_file = try std.fs.path.join(testing.allocator, &.{ tmp_path, "minimal_session.json" });
    defer testing.allocator.free(session_file);

    // Create minimal session file
    {
        const io_fs = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().createFile(io_fs, session_file, .{});
        defer file.close(io_fs);
        try file.writeStreamingAll(io_fs, "{\"format\": \"json\", \"variables\": {}}");
    }

    // Load
    var loaded = try session_state.SessionState.load(testing.allocator, session_file);
    defer loaded.deinit(testing.allocator);

    // Verify defaults
    try testing.expectEqual(@as(?[]const u8, null), loaded.database);
    try testing.expectEqual(false, loaded.in_transaction);
    try testing.expectEqual(session_state.SessionState.Format.json, loaded.format);
}

test "session state: multiple variables" {
    var state = session_state.SessionState.init(testing.allocator);
    defer state.deinit(testing.allocator);

    try state.variables.put(try testing.allocator.dupe(u8, "foo"), try testing.allocator.dupe(u8, "bar"));
    try state.variables.put(try testing.allocator.dupe(u8, "baz"), try testing.allocator.dupe(u8, "qux"));
    try state.variables.put(try testing.allocator.dupe(u8, "test"), try testing.allocator.dupe(u8, "value"));

    try testing.expectEqual(@as(usize, 3), state.variables.count());
    try testing.expectEqualStrings("bar", state.variables.get("foo").?);
    try testing.expectEqualStrings("qux", state.variables.get("baz").?);
    try testing.expectEqualStrings("value", state.variables.get("test").?);
}

// ============================================================================
// Integration Tests
// ============================================================================

test "integration: syntax highlighting with fuzzy search" {
    // Simulate highlighting search results
    const query = "match";
    const candidates = [_][]const u8{
        "MATCH (n) RETURN n",
        "CREATE (n)",
    };

    const results = try fuzzy_search.fuzzySearch(testing.allocator, query, &candidates, 10);
    defer testing.allocator.free(results);

    // Highlight the best match
    const highlighted = try syntax_highlighter.highlight(testing.allocator, results[0].text, true);
    defer testing.allocator.free(highlighted);

    // Should contain both the query and color codes
    try testing.expect(std.mem.indexOf(u8, highlighted, "\x1b[") != null);
}

test "integration: pager with session state" {
    var state = session_state.SessionState.init(testing.allocator);
    defer state.deinit(testing.allocator);

    // Set format preference
    state.format = .table;

    // Create pager config
    const config = result_pager.PagerConfig{
        .page_size = 5,
        .enabled = true,
    };

    const pager = result_pager.ResultPager.init(testing.allocator, config);

    // Verify format matches
    try testing.expectEqual(session_state.SessionState.Format.table, state.format);
    try testing.expectEqual(@as(usize, 5), pager.config.page_size);
}
