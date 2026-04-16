// CANARY: REQ=REQ-DOCUMENTATION-SYSTEM-INTEGRATION-001; FEATURE="Documentation System Integration Tests"; ASPECT=IntegrationTests; STATUS=EXEMPT; TEST=TestCANARY_REQ_DOCUMENTATION_SYSTEM_INTEGRATION_001; OWNER=claude; UPDATED=2025-10-05
// Integration tests for documentation system coherence and navigation

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;

test "Documentation link integrity across all files" {
    // Test that all documentation links in CLAUDE.md point to existing files
    var gpa = std.heap.DebugAllocator(.{});
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const content = std.fs.cwd().readFileAlloc(allocator, "CLAUDE.md", 50000) catch |err| {
        std.debug.print("Failed to read CLAUDE.md: {}\n", .{err});
        try expect(false);
        return;
    };
    defer allocator.free(content);

    // Extract all docs/ links from CLAUDE.md
    var link_count: u32 = 0;
    var search_pos: usize = 0;

    while (std.mem.indexOfPos(u8, content, search_pos, "](docs/")) |start_pos| {
        const link_start = start_pos + 2; // Skip "]("
        if (std.mem.indexOfPos(u8, content, link_start, ")")) |end_pos| {
            const link_path = content[link_start..end_pos];

            // Verify the linked file exists
            std.fs.cwd().access(link_path, .{}) catch |err| {
                std.debug.print("Broken documentation link: {} (error: {})\n", .{ link_path, err });
                try expect(false);
            };

            link_count += 1;
            search_pos = end_pos + 1;
        } else {
            break;
        }
    }

    // Should have found and validated multiple links
    try expect(link_count >= 5);
    std.log.info("Validated {} documentation links", .{link_count});
}

test "Essential documentation files exist and are accessible" {
    // Test that all essential documentation files exist and can be read
    const essential_docs = [_][]const u8{
        "docs/README.md",
        "docs/IMPLEMENTATION_STATUS.md",
        "docs/TODO.md",
        "docs/API_REFERENCE.md",
        "docs/TYPES_AND_FUNCTIONS.md",
        "docs/GQL_COMPLIANCE.md",
        "docs/PERFORMANCE_ANALYSIS_REPORT.md",
        "docs/QUICK_REFERENCE.md",
    };

    for (essential_docs) |doc_path| {
        // Verify file exists
        std.fs.cwd().access(doc_path, .{}) catch |err| {
            std.debug.print("Essential documentation missing: {} (error: {})\n", .{ doc_path, err });
            try expect(false);
        };

        // Verify file is readable and has content
        var gpa = std.heap.DebugAllocator(.{});
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        const content = std.fs.cwd().readFileAlloc(allocator, doc_path, 1024 * 1024) catch |err| {
            std.debug.print("Cannot read documentation: {} (error: {})\n", .{ doc_path, err });
            try expect(false);
            continue;
        };
        defer allocator.free(content);

        // Should have substantial content (not empty files)
        try expect(content.len > 100);
    }
}

test "Documentation cross-reference validation" {
    // Test that documentation files properly reference each other
    var gpa = std.heap.DebugAllocator(.{});
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Check that docs/README.md properly indexes other documentation
    const readme_content = std.fs.cwd().readFileAlloc(allocator, "docs/README.md", 100000) catch |err| {
        std.debug.print("Failed to read docs/README.md: {}\n", .{err});
        try expect(false);
        return;
    };
    defer allocator.free(readme_content);

    // README should reference major documentation files
    const referenced_docs = [_][]const u8{
        "IMPLEMENTATION_STATUS.md",
        "TODO.md",
        "API_REFERENCE.md",
        "TYPES_AND_FUNCTIONS.md",
        "GQL_COMPLIANCE.md",
    };

    for (referenced_docs) |doc_name| {
        try expect(std.mem.indexOf(u8, readme_content, doc_name) != null);
    }

    // Should have proper markdown structure
    try expect(std.mem.indexOf(u8, readme_content, "# ") != null); // Main header
    try expect(std.mem.indexOf(u8, readme_content, "## ") != null); // Section headers
}

test "Documentation consistency across feature implementations" {
    // Test that recently implemented features have corresponding documentation
    var gpa = std.heap.DebugAllocator(.{});
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Check that major features mentioned in CLAUDE.md have detailed docs
    const claude_content = std.fs.cwd().readFileAlloc(allocator, "CLAUDE.md", 50000) catch |err| {
        std.debug.print("Failed to read CLAUDE.md: {}\n", .{err});
        try expect(false);
        return;
    };
    defer allocator.free(claude_content);

    // Features that should have documentation based on recent implementations
    const documented_features = [_]struct { name: []const u8, doc_file: []const u8 }{
        .{ .name = "ML Graph Embeddings", .doc_file = "docs/ML_GRAPH_EMBEDDINGS.md" },
        .{ .name = "Real-time Analytics", .doc_file = "docs/REAL_TIME_ANALYTICS.md" },
        .{ .name = "Enhanced Transaction Isolation", .doc_file = "docs/ENHANCED_TRANSACTION_ISOLATION.md" },
        .{ .name = "Distributed Query Coordination", .doc_file = "docs/DISTRIBUTED_QUERY_COORDINATION.md" },
        .{ .name = "CLI Subprocess Elimination", .doc_file = "docs/CLI_SUBPROCESS_ELIMINATION.md" },
        .{ .name = "Materialized Views", .doc_file = "docs/MATERIALIZED_VIEWS.md" },
    };

    for (documented_features) |feature_doc| {
        // Feature should be mentioned in CLAUDE.md
        try expect(std.mem.indexOf(u8, claude_content, feature_doc.name) != null);

        // Corresponding documentation file should exist
        std.fs.cwd().access(feature_doc.doc_file, .{}) catch |err| {
            std.debug.print("Missing feature documentation: {} for feature: {} (error: {})\n", .{ feature_doc.doc_file, feature_doc.name, err });
            try expect(false);
        };

        // Documentation file should have substantial content
        const doc_content = std.fs.cwd().readFileAlloc(allocator, feature_doc.doc_file, 100000) catch |err| {
            std.debug.print("Cannot read feature documentation: {} (error: {})\n", .{ feature_doc.doc_file, err });
            try expect(false);
            continue;
        };
        defer allocator.free(doc_content);

        try expect(doc_content.len > 1000); // Should be comprehensive documentation
    }
}

test "Documentation navigation workflow efficiency" {
    // Test that users can efficiently navigate from CLAUDE.md to detailed information
    var gpa = std.heap.DebugAllocator(.{});
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Start from CLAUDE.md (entry point)
    const claude_content = std.fs.cwd().readFileAlloc(allocator, "CLAUDE.md", 50000) catch |err| {
        std.debug.print("Failed to read CLAUDE.md: {}\n", .{err});
        try expect(false);
        return;
    };
    defer allocator.free(claude_content);

    // Should have clear section for documentation navigation
    try expect(std.mem.indexOf(u8, claude_content, "Documentation") != null);
    try expect(std.mem.indexOf(u8, claude_content, "docs/README.md") != null);

    // Follow the navigation to docs/README.md
    const readme_content = std.fs.cwd().readFileAlloc(allocator, "docs/README.md", 100000) catch |err| {
        std.debug.print("Failed to read docs/README.md: {}\n", .{err});
        try expect(false);
        return;
    };
    defer allocator.free(readme_content);

    // README should provide comprehensive navigation
    try expect(std.mem.indexOf(u8, readme_content, "API_REFERENCE.md") != null);
    try expect(std.mem.indexOf(u8, readme_content, "TYPES_AND_FUNCTIONS.md") != null);
    try expect(std.mem.indexOf(u8, readme_content, "IMPLEMENTATION_STATUS.md") != null);

    // Test one more level: Follow link to a specific detailed document
    const impl_status_content = std.fs.cwd().readFileAlloc(allocator, "docs/IMPLEMENTATION_STATUS.md", 500000) catch |err| {
        std.debug.print("Failed to read docs/IMPLEMENTATION_STATUS.md: {}\n", .{err});
        try expect(false);
        return;
    };
    defer allocator.free(impl_status_content);

    // Should contain detailed implementation information
    try expect(impl_status_content.len > 5000); // Should be comprehensive
    try expect(std.mem.indexOf(u8, impl_status_content, "CANARY") != null); // Should track governance
}

test "Documentation system performance under load" {
    // Test that documentation system performs well when accessing multiple files
    const start_time = std.time.nanoTimestamp();

    var gpa = std.heap.DebugAllocator(.{});
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Simulate user navigating through multiple documentation files
    const docs_to_load = [_][]const u8{
        "CLAUDE.md",
        "docs/README.md",
        "docs/IMPLEMENTATION_STATUS.md",
        "docs/API_REFERENCE.md",
        "docs/TYPES_AND_FUNCTIONS.md",
        "docs/TODO.md",
    };

    var total_chars_loaded: usize = 0;

    for (docs_to_load) |doc_path| {
        const content = std.fs.cwd().readFileAlloc(allocator, doc_path, 1024 * 1024) catch |err| {
            std.debug.print("Failed to load {} during performance test: {}\n", .{ doc_path, err });
            try expect(false);
            continue;
        };
        defer allocator.free(content);

        total_chars_loaded += content.len;
    }

    const end_time = std.time.nanoTimestamp();
    const duration_ns = end_time - start_time;
    const duration_ms = duration_ns / 1_000_000;

    // Should load all documentation quickly (under 100ms)
    try expect(duration_ms < 100);

    // Should have loaded substantial amount of documentation
    try expect(total_chars_loaded > 50000);

    std.log.info("Loaded {} characters of documentation in {}ms", .{ total_chars_loaded, duration_ms });
}

test "Documentation version consistency and freshness" {
    // Test that documentation reflects current implementation status
    var gpa = std.heap.DebugAllocator(.{});
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Check CLAUDE.md for current date references
    const claude_content = std.fs.cwd().readFileAlloc(allocator, "CLAUDE.md", 50000) catch |err| {
        std.debug.print("Failed to read CLAUDE.md: {}\n", .{err});
        try expect(false);
        return;
    };
    defer allocator.free(claude_content);

    // Should reference current development timeframe (October 2025)
    try expect(std.mem.indexOf(u8, claude_content, "October 2025") != null or
        std.mem.indexOf(u8, claude_content, "2025") != null);

    // Check implementation status for freshness
    const impl_content = std.fs.cwd().readFileAlloc(allocator, "docs/IMPLEMENTATION_STATUS.md", 500000) catch |err| {
        std.debug.print("Failed to read docs/IMPLEMENTATION_STATUS.md: {}\n", .{err});
        try expect(false);
        return;
    };
    defer allocator.free(impl_content);

    // Should contain recent implementation references
    try expect(std.mem.indexOf(u8, impl_content, "2025") != null);
    try expect(std.mem.indexOf(u8, impl_content, "CANARY") != null);

    // Check TODO for current priorities
    const todo_content = std.fs.cwd().readFileAlloc(allocator, "docs/TODO.md", 100000) catch |err| {
        std.debug.print("Failed to read docs/TODO.md: {}\n", .{err});
        try expect(false);
        return;
    };
    defer allocator.free(todo_content);

    // Should contain current development priorities
    try expect(std.mem.indexOf(u8, todo_content, "Priority") != null or
        std.mem.indexOf(u8, todo_content, "HIGH") != null);
}

test "Documentation accessibility and user experience" {
    // Test that documentation is accessible to developers and users
    var gpa = std.heap.DebugAllocator(.{});
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test CLAUDE.md as primary entry point
    const claude_content = std.fs.cwd().readFileAlloc(allocator, "CLAUDE.md", 50000) catch |err| {
        std.debug.print("Failed to read CLAUDE.md: {}\n", .{err});
        try expect(false);
        return;
    };
    defer allocator.free(claude_content);

    // Should have clear structure with emoji headers for visual navigation
    try expect(std.mem.indexOf(u8, claude_content, "🏆") != null); // Project status
    try expect(std.mem.indexOf(u8, claude_content, "📚") != null); // Documentation
    try expect(std.mem.indexOf(u8, claude_content, "🔧") != null); // Development

    // Should provide quick access to essential information
    try expect(std.mem.indexOf(u8, claude_content, "Test Coverage") != null);
    try expect(std.mem.indexOf(u8, claude_content, "GQL Compliance") != null);
    try expect(std.mem.indexOf(u8, claude_content, "make build") != null);
    try expect(std.mem.indexOf(u8, claude_content, "make test") != null);

    // Check that README provides good navigation structure
    const readme_content = std.fs.cwd().readFileAlloc(allocator, "docs/README.md", 100000) catch |err| {
        std.debug.print("Failed to read docs/README.md: {}\n", .{err});
        try expect(false);
        return;
    };
    defer allocator.free(readme_content);

    // Should have organized sections for different user needs
    try expect(std.mem.indexOf(u8, readme_content, "##") != null); // Section headers
    try expect(readme_content.len > 1000); // Should be comprehensive
}

test "Documentation build integration and CI compatibility" {
    // Test that documentation integrates well with build system

    // Documentation files should not interfere with build process
    // by checking that they are in proper locations

    // Check that docs/ directory exists and is properly structured
    var docs_dir = std.fs.cwd().openDir("docs", .{}) catch |err| {
        std.debug.print("docs/ directory not accessible: {}\n", .{err});
        try expect(false);
        return;
    };
    defer docs_dir.close();

    // Verify that essential documentation files are in docs/ directory (not in src/)
    const docs_in_proper_location = [_][]const u8{
        "README.md",
        "IMPLEMENTATION_STATUS.md",
        "TODO.md",
        "API_REFERENCE.md",
    };

    for (docs_in_proper_location) |doc_file| {
        docs_dir.access(doc_file, .{}) catch |err| {
            std.debug.print("Documentation file not in docs/: {} (error: {})\n", .{ doc_file, err });
            try expect(false);
        };
    }

    // Verify that CLAUDE.md is in root (proper location for Claude Code)
    std.fs.cwd().access("CLAUDE.md", .{}) catch |err| {
        std.debug.print("CLAUDE.md not in root directory: {}\n", .{err});
        try expect(false);
    };
}

// CANARY compliance test
test "TestCANARY_REQ_DOCUMENTATION_SYSTEM_INTEGRATION_001" {
    // This test verifies documentation system integration functionality
    // as specified in REQ-DOCUMENTATION-SYSTEM-INTEGRATION-001

    var gpa = std.heap.DebugAllocator(.{});
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // REQ-DOCUMENTATION-SYSTEM-INTEGRATION-001: Link integrity
    const claude_content = std.fs.cwd().readFileAlloc(allocator, "CLAUDE.md", 50000) catch |err| {
        std.debug.print("CANARY test failed - CLAUDE.md not accessible: {}\n", .{err});
        try expect(false);
        return;
    };
    defer allocator.free(claude_content);

    // Verify link integrity for core documentation
    var verified_links: u32 = 0;
    var search_pos: usize = 0;

    while (std.mem.indexOfPos(u8, claude_content, search_pos, "](docs/")) |start_pos| {
        const link_start = start_pos + 2;
        if (std.mem.indexOfPos(u8, claude_content, link_start, ")")) |end_pos| {
            const link_path = claude_content[link_start..end_pos];

            // Verify each linked file exists
            std.fs.cwd().access(link_path, .{}) catch |err| {
                std.debug.print("CANARY test failed - broken link: {} (error: {})\n", .{ link_path, err });
                try expect(false);
            };

            verified_links += 1;
            search_pos = end_pos + 1;
        } else {
            break;
        }
    }

    // REQ-DOCUMENTATION-SYSTEM-INTEGRATION-001: Minimum link coverage
    try expect(verified_links >= 5);

    // REQ-DOCUMENTATION-SYSTEM-INTEGRATION-001: Essential documentation accessibility
    const essential_files = [_][]const u8{
        "docs/README.md",
        "docs/IMPLEMENTATION_STATUS.md",
        "docs/TODO.md",
    };

    for (essential_files) |file_path| {
        std.fs.cwd().access(file_path, .{}) catch |err| {
            std.debug.print("CANARY test failed - essential doc missing: {} (error: {})\n", .{ file_path, err });
            try expect(false);
        };
    }

    // Log successful CANARY test completion
    std.log.info("CANARY documentation system integration test passed: {} links verified, essential docs accessible", .{verified_links});
}
