// CANARY: REQ=REQ-DOCUMENTATION-STRUCTURE-001; FEATURE="Documentation Structure Tests"; ASPECT=UnitTests; STATUS=EXEMPT; TEST=TestCANARY_REQ_DOCUMENTATION_STRUCTURE_001; OWNER=claude; UPDATED=2025-10-05
// Unit tests for documentation structure validation

const std = @import("std");
const testing = std.testing;
const expect = testing.expect;

test "CLAUDE.md file size constraint validation" {
    // Test that CLAUDE.md remains under 20,000 character limit
    const file = std.fs.cwd().openFile("CLAUDE.md", .{}) catch |err| {
        std.debug.print("Failed to open CLAUDE.md: {}\n", .{err});
        try expect(false);
        return;
    };
    defer file.close();

    const file_size = try file.getEndPos();

    // Verify file size is under 20,000 characters (user requirement)
    try expect(file_size < 20000);

    // Log the actual size for monitoring
    std.log.info("CLAUDE.md file size: {} characters", .{file_size});

    // Additional constraint: should be reasonable for quick reading (under 15,000)
    try expect(file_size < 15000);
}

test "Essential project information presence in CLAUDE.md" {
    // Test that CLAUDE.md contains essential project guidance
    var gpa = std.heap.GeneralPurposeAllocator(.{});
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const content = std.fs.cwd().readFileAlloc(allocator, "CLAUDE.md", 50000) catch |err| {
        std.debug.print("Failed to read CLAUDE.md: {}\n", .{err});
        try expect(false);
        return;
    };
    defer allocator.free(content);

    // Essential sections that must be present
    try expect(std.mem.indexOf(u8, content, "## 🏆 Project Status") != null);
    try expect(std.mem.indexOf(u8, content, "Test Coverage") != null);
    try expect(std.mem.indexOf(u8, content, "GQL Compliance") != null);
    try expect(std.mem.indexOf(u8, content, "CANARY Markers") != null);
    try expect(std.mem.indexOf(u8, content, "Enterprise Features") != null);

    // Documentation structure section
    try expect(std.mem.indexOf(u8, content, "## 📚 Documentation Structure") != null);
    try expect(std.mem.indexOf(u8, content, "docs/") != null);

    // Development commands section
    try expect(std.mem.indexOf(u8, content, "## 🔧 Development Commands") != null);
    try expect(std.mem.indexOf(u8, content, "make build") != null);
    try expect(std.mem.indexOf(u8, content, "make test") != null);

    // Current focus areas
    try expect(std.mem.indexOf(u8, content, "Current Focus") != null or
        std.mem.indexOf(u8, content, "Priority") != null);
}

test "Documentation links structure validation" {
    // Test that CLAUDE.md contains proper links to detailed documentation
    var gpa = std.heap.GeneralPurposeAllocator(.{});
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const content = std.fs.cwd().readFileAlloc(allocator, "CLAUDE.md", 50000) catch |err| {
        std.debug.print("Failed to read CLAUDE.md: {}\n", .{err});
        try expect(false);
        return;
    };
    defer allocator.free(content);

    // Essential documentation links that should be present
    const expected_links = [_][]const u8{
        "docs/README.md",
        "docs/IMPLEMENTATION_STATUS.md",
        "docs/TODO.md",
        "docs/API_REFERENCE.md",
        "docs/TYPES_AND_FUNCTIONS.md",
    };

    for (expected_links) |link| {
        try expect(std.mem.indexOf(u8, content, link) != null);
    }

    // Should have link format: [Text](docs/FILE.md)
    try expect(std.mem.indexOf(u8, content, "](docs/") != null);
    try expect(std.mem.indexOf(u8, content, ".md)") != null);
}

test "Reference architecture link format validation" {
    // Test that documentation links follow consistent format
    var gpa = std.heap.GeneralPurposeAllocator(.{});
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const content = std.fs.cwd().readFileAlloc(allocator, "CLAUDE.md", 50000) catch |err| {
        std.debug.print("Failed to read CLAUDE.md: {}\n", .{err});
        try expect(false);
        return;
    };
    defer allocator.free(content);

    // Count markdown links to docs directory
    var link_count: u32 = 0;
    var search_pos: usize = 0;

    while (std.mem.indexOfPos(u8, content, search_pos, "](docs/")) |pos| {
        link_count += 1;
        search_pos = pos + 7; // Move past "](docs/"
    }

    // Should have multiple documentation links (at least 5)
    try expect(link_count >= 5);

    // Log link count for monitoring
    std.log.info("Found {} documentation links in CLAUDE.md", .{link_count});

    // Verify link consistency - no broken link patterns
    try expect(std.mem.indexOf(u8, content, "](docs/)") == null); // No empty paths
    try expect(std.mem.indexOf(u8, content, "](docs/.md)") == null); // No invalid filenames
}

test "Essential guidance sections structure" {
    // Test that CLAUDE.md maintains proper section hierarchy
    var gpa = std.heap.GeneralPurposeAllocator(.{});
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const content = std.fs.cwd().readFileAlloc(allocator, "CLAUDE.md", 50000) catch |err| {
        std.debug.print("Failed to read CLAUDE.md: {}\n", .{err});
        try expect(false);
        return;
    };
    defer allocator.free(content);

    // Essential section headers that provide guidance structure
    const required_sections = [_][]const u8{
        "# CLAUDE.md",
        "## 🏆 Project Status",
        "## 📚 Documentation Structure",
        "## 🔧 Development Commands",
    };

    for (required_sections) |section| {
        try expect(std.mem.indexOf(u8, content, section) != null);
    }

    // Should have proper markdown hierarchy (## for main sections)
    var main_section_count: u32 = 0;
    var search_pos: usize = 0;

    while (std.mem.indexOfPos(u8, content, search_pos, "\n## ")) |pos| {
        main_section_count += 1;
        search_pos = pos + 4;
    }

    // Should have reasonable number of main sections (at least 3, but not excessive)
    try expect(main_section_count >= 3);
    try expect(main_section_count <= 10); // Prevent section bloat
}

test "No excessive detail in streamlined CLAUDE.md" {
    // Test that CLAUDE.md doesn't contain overly detailed implementation content
    var gpa = std.heap.GeneralPurposeAllocator(.{});
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const content = std.fs.cwd().readFileAlloc(allocator, "CLAUDE.md", 50000) catch |err| {
        std.debug.print("Failed to read CLAUDE.md: {}\n", .{err});
        try expect(false);
        return;
    };
    defer allocator.free(content);

    // Should not contain excessive code blocks or implementation details
    var code_block_count: u32 = 0;
    var search_pos: usize = 0;

    while (std.mem.indexOfPos(u8, content, search_pos, "```")) |pos| {
        code_block_count += 1;
        search_pos = pos + 3;
    }

    // Code blocks should be minimal in streamlined version (under 20 blocks)
    try expect(code_block_count < 20);

    // Should not contain overly detailed implementation patterns
    const excessive_detail_indicators = [_][]const u8{
        "std.ArrayList",
        "const allocator",
        "fn main()",
        "pub const",
        "try expect",
    };

    for (excessive_detail_indicators) |indicator| {
        // These should be rare or absent in streamlined guidance
        const occurrences = std.mem.count(u8, content, indicator);
        try expect(occurrences < 3); // Allow minimal usage but prevent excessive detail
    }
}

test "Performance characteristics of streamlined CLAUDE.md" {
    // Test that the streamlined file has good performance characteristics
    const start_time = std.time.nanoTimestamp();

    var gpa = std.heap.GeneralPurposeAllocator(.{});
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const content = std.fs.cwd().readFileAlloc(allocator, "CLAUDE.md", 50000) catch |err| {
        std.debug.print("Failed to read CLAUDE.md: {}\n", .{err});
        try expect(false);
        return;
    };
    defer allocator.free(content);

    const end_time = std.time.nanoTimestamp();
    const duration_ns = end_time - start_time;
    const duration_ms = duration_ns / 1_000_000;

    // Should load quickly (under 10ms for reasonable hardware)
    try expect(duration_ms < 50); // Allow some variance for test environments

    // Log performance metrics
    std.log.info("CLAUDE.md load time: {}ms, size: {} characters", .{ duration_ms, content.len });

    // Content should be readable size (not too short, not too long)
    try expect(content.len > 5000); // Should have substantial guidance
    try expect(content.len < 20000); // Should not be oversized
}

test "Markdown format validity in CLAUDE.md" {
    // Test that CLAUDE.md maintains valid markdown structure
    var gpa = std.heap.GeneralPurposeAllocator(.{});
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const content = std.fs.cwd().readFileAlloc(allocator, "CLAUDE.md", 50000) catch |err| {
        std.debug.print("Failed to read CLAUDE.md: {}\n", .{err});
        try expect(false);
        return;
    };
    defer allocator.free(content);

    // Basic markdown validation

    // Headers should have space after #
    try expect(std.mem.indexOf(u8, content, "##No") == null); // Should be "## No"
    try expect(std.mem.indexOf(u8, content, "#No") == null); // Should be "# No"

    // Lists should have proper formatting
    try expect(std.mem.indexOf(u8, content, "-**") == null); // Should be "- **"

    // Links should be properly formatted
    var malformed_link_count: u32 = 0;
    var search_pos: usize = 0;

    // Look for common malformed link patterns
    const malformed_patterns = [_][]const u8{
        "[](", // Empty link text
        "]()", // Empty link target
        "[[", // Double bracket (not markdown)
        "]]", // Double bracket (not markdown)
    };

    for (malformed_patterns) |pattern| {
        if (std.mem.indexOf(u8, content, pattern)) |_| {
            malformed_link_count += 1;
        }
    }

    try expect(malformed_link_count == 0);
}

test "CANARY compliance markers in documentation structure" {
    // Test that documentation includes proper CANARY governance tracking
    var gpa = std.heap.GeneralPurposeAllocator(.{});
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const content = std.fs.cwd().readFileAlloc(allocator, "CLAUDE.md", 50000) catch |err| {
        std.debug.print("Failed to read CLAUDE.md: {}\n", .{err});
        try expect(false);
        return;
    };
    defer allocator.free(content);

    // Should reference CANARY compliance tracking
    try expect(std.mem.indexOf(u8, content, "CANARY") != null);

    // Should indicate proper governance
    try expect(std.mem.indexOf(u8, content, "compliance") != null or
        std.mem.indexOf(u8, content, "governance") != null);
}

// CANARY compliance test
test "TestCANARY_REQ_DOCUMENTATION_STRUCTURE_001" {
    // CANARY: This test verifies documentation structure functionality
    // as specified in REQ-DOCUMENTATION-STRUCTURE-001

    var gpa = std.heap.GeneralPurposeAllocator(.{});
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Verify CLAUDE.md exists and is properly structured
    const content = std.fs.cwd().readFileAlloc(allocator, "CLAUDE.md", 50000) catch |err| {
        std.debug.print("CANARY test failed - CLAUDE.md not accessible: {}\n", .{err});
        try expect(false);
        return;
    };
    defer allocator.free(content);

    // Verify essential CANARY requirements
    const file_size = content.len;

    // REQ-DOCUMENTATION-STRUCTURE-001: File size constraint
    try expect(file_size < 20000);

    // REQ-DOCUMENTATION-STRUCTURE-001: Essential information preservation
    try expect(std.mem.indexOf(u8, content, "Project Status") != null);
    try expect(std.mem.indexOf(u8, content, "Documentation Structure") != null);

    // REQ-DOCUMENTATION-STRUCTURE-001: Reference architecture
    try expect(std.mem.indexOf(u8, content, "docs/") != null);

    // Log successful CANARY test completion
    std.log.info("CANARY documentation structure test passed: size={} chars, links verified", .{file_size});
}
