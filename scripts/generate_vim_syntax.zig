// CANARY: REQ=REQ-SYNTAX-VIM-001; FEATURE="VimSyntaxGeneration"; ASPECT=MetadataDerived; STATUS=EXEMPT; OWNER=tooling; UPDATED=2026-01-03
//! # Vim/Neovim Syntax Generator
//!
//! Generates Vim syntax highlighting (gql.vim) from the unified language_metadata.zig.
//! This ensures syntax highlighting stays in sync with the language definition.
//!
//! ## Usage
//!     zig build generate-vim-syntax
//!
//! Output: editors/vim/syntax/gql.vim

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");
const language_metadata = geode.language_metadata;

const KeywordCategory = language_metadata.KeywordCategory;
const FunctionCategory = language_metadata.FunctionCategory;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try generateVimSyntaxToStdout(allocator);
}

fn generateVimSyntaxToStdout(allocator: std.mem.Allocator) !void {
    var output = try std.ArrayList(u8).initCapacity(allocator, 16384);
    defer output.deinit(allocator);

    try generateVimSyntax(allocator, &output);

    const io = std.Io.Threaded.global_single_threaded.io();
    const stdout = std.Io.File.stdout();
    var write_buf: [8192]u8 = undefined;
    var writer = stdout.writer(io, &write_buf);
    try writer.interface.writeAll(output.items);
    try writer.interface.flush();
}

fn generateVimSyntax(allocator: std.mem.Allocator, output: *std.ArrayList(u8)) !void {
    // Header
    try output.appendSlice(allocator,
        \\" Vim syntax file
        \\" Language: GQL (Graph Query Language)
        \\" Maintainer: Geode Team
        \\" Latest Revision: 2026-01-03
        \\" Generated from language_metadata.zig - DO NOT EDIT MANUALLY
        \\
        \\if exists("b:current_syntax")
        \\  finish
        \\endif
        \\
        \\let s:cpo_save = &cpo
        \\set cpo&vim
        \\
        \\" Case insensitive matching
        \\syn case ignore
        \\
        \\" Comments
        \\syn match gqlComment "--.*$" contains=gqlTodo
        \\syn match gqlComment "//.*$" contains=gqlTodo
        \\syn region gqlComment start="/\*" end="\*/" contains=gqlTodo
        \\syn keyword gqlTodo contained TODO FIXME XXX NOTE HACK BUG
        \\
        \\" Strings
        \\syn region gqlString start="'" end="'" skip="\\\\'"
        \\syn region gqlString start='"' end='"' skip='\\\\"'
        \\
        \\" Numbers
        \\syn match gqlNumber "\<\d\+\>"
        \\syn match gqlNumber "\<\d\+\.\d\+\>"
        \\syn match gqlNumber "\<\d\+\.\d\+[eE][+-]\?\d\+\>"
        \\
        \\" Variables (parameters)
        \\syn match gqlVariable "\$[a-zA-Z_][a-zA-Z0-9_]*"
        \\
        \\" Labels
        \\syn match gqlLabel ":[a-zA-Z_][a-zA-Z0-9_]*"
        \\
        \\" Operators
        \\syn match gqlOperator "=\|<>\|<\|>\|<=\|>="
        \\syn match gqlOperator "+\|-\|\*\|/\|%\|\^"
        \\syn match gqlOperator "||\|&&"
        \\syn match gqlOperator "->\|<-\|=>"
        \\
        \\
    );

    // Categorize keywords
    var clause_keywords = try std.ArrayList([]const u8).initCapacity(allocator, 32);
    defer clause_keywords.deinit(allocator);
    var boolean_keywords = try std.ArrayList([]const u8).initCapacity(allocator, 32);
    defer boolean_keywords.deinit(allocator);
    var ddl_keywords = try std.ArrayList([]const u8).initCapacity(allocator, 16);
    defer ddl_keywords.deinit(allocator);
    var transaction_keywords = try std.ArrayList([]const u8).initCapacity(allocator, 16);
    defer transaction_keywords.deinit(allocator);
    var other_keywords = try std.ArrayList([]const u8).initCapacity(allocator, 64);
    defer other_keywords.deinit(allocator);

    for (language_metadata.keywords) |kw| {
        switch (kw.category) {
            .clause => try clause_keywords.append(allocator, kw.name),
            .boolean_operator, .literal, .comparison => try boolean_keywords.append(allocator, kw.name),
            .ddl => try ddl_keywords.append(allocator, kw.name),
            .transaction => try transaction_keywords.append(allocator, kw.name),
            .modifier, .ordering, .aggregation, .type_keyword, .temporal, .session, .reserved, .path_pattern, .set_operation => try other_keywords.append(allocator, kw.name),
        }
    }

    // Categorize functions
    var aggregate_functions = try std.ArrayList([]const u8).initCapacity(allocator, 8);
    defer aggregate_functions.deinit(allocator);
    var scalar_functions = try std.ArrayList([]const u8).initCapacity(allocator, 64);
    defer scalar_functions.deinit(allocator);

    for (language_metadata.functions) |f| {
        switch (f.category) {
            .aggregate => try aggregate_functions.append(allocator, f.name),
            else => try scalar_functions.append(allocator, f.name),
        }
    }

    // Write clause keywords
    try output.appendSlice(allocator, "\" Clause keywords (MATCH, CREATE, DELETE, etc.)\nsyn keyword gqlKeyword ");
    try writeVimKeywordList(allocator, output, clause_keywords.items);
    try output.appendSlice(allocator, "\n\n");

    // Write boolean/logical keywords
    try output.appendSlice(allocator, "\" Boolean and logical keywords\nsyn keyword gqlBoolean ");
    try writeVimKeywordList(allocator, output, boolean_keywords.items);
    try output.appendSlice(allocator, "\n\n");

    // Write DDL keywords
    try output.appendSlice(allocator, "\" DDL keywords\nsyn keyword gqlDDL ");
    try writeVimKeywordList(allocator, output, ddl_keywords.items);
    try output.appendSlice(allocator, "\n\n");

    // Write transaction keywords
    try output.appendSlice(allocator, "\" Transaction keywords\nsyn keyword gqlTransaction ");
    try writeVimKeywordList(allocator, output, transaction_keywords.items);
    try output.appendSlice(allocator, "\n\n");

    // Write other keywords
    try output.appendSlice(allocator, "\" Other keywords\nsyn keyword gqlKeyword ");
    try writeVimKeywordList(allocator, output, other_keywords.items);
    try output.appendSlice(allocator, "\n\n");

    // Write aggregate functions
    try output.appendSlice(allocator, "\" Aggregate functions\nsyn keyword gqlAggregate ");
    try writeVimKeywordList(allocator, output, aggregate_functions.items);
    try output.appendSlice(allocator, "\n\n");

    // Write scalar functions
    try output.appendSlice(allocator, "\" Scalar functions\nsyn keyword gqlFunction ");
    try writeVimKeywordList(allocator, output, scalar_functions.items);
    try output.appendSlice(allocator, "\n\n");

    // Write types
    try output.appendSlice(allocator, "\" Data types\nsyn keyword gqlType ");
    for (language_metadata.types, 0..) |t, i| {
        if (i > 0) try output.appendSlice(allocator, " ");
        try output.appendSlice(allocator, t.name);
    }
    try output.appendSlice(allocator, "\n\n");

    // Highlighting links
    try output.appendSlice(allocator,
        \\" Highlighting
        \\hi def link gqlComment Comment
        \\hi def link gqlTodo Todo
        \\hi def link gqlString String
        \\hi def link gqlNumber Number
        \\hi def link gqlVariable Identifier
        \\hi def link gqlLabel Type
        \\hi def link gqlOperator Operator
        \\hi def link gqlKeyword Statement
        \\hi def link gqlBoolean Boolean
        \\hi def link gqlDDL Keyword
        \\hi def link gqlTransaction Special
        \\hi def link gqlAggregate Function
        \\hi def link gqlFunction Function
        \\hi def link gqlType Type
        \\
        \\let b:current_syntax = "gql"
        \\
        \\let &cpo = s:cpo_save
        \\unlet s:cpo_save
        \\
    );
}

fn writeVimKeywordList(allocator: std.mem.Allocator, output: *std.ArrayList(u8), items: []const []const u8) !void {
    for (items, 0..) |item, i| {
        if (i > 0) try output.appendSlice(allocator, " ");
        try output.appendSlice(allocator, item);
    }
}

test "generate vim syntax produces valid output" {
    var output = std.ArrayList(u8).init(std.testing.allocator);
    defer output.deinit();
    try generateVimSyntax(std.testing.allocator, output.writer());

    try std.testing.expect(std.mem.startsWith(u8, output.items, "\" Vim syntax file"));
    try std.testing.expect(std.mem.indexOf(u8, output.items, "syn keyword gqlKeyword") != null);
}
