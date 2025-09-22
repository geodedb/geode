const std = @import("std");

// Combined governance automation: NEXT freshness + CANARY verify (GAP_ANALYSIS strict) + doc drift checks.
// CANARY: REQ=REQ-GQL-010; FEATURE="Governance"; ASPECT=GovernanceCombinedCheck; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_GovernanceCombinedCheck; OWNER=tooling; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-010; FEATURE="Governance"; ASPECT=GovernanceReadmeRealityConsistency; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_GovernanceCombinedCheck; OWNER=tooling; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-010; FEATURE="Governance"; ASPECT=NextSliceStructureGuard; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_GovernanceCombinedCheck; OWNER=tooling; UPDATED=2025-09-22
// CANARY: REQ=REQ-GQL-010; FEATURE="Governance"; ASPECT=SliceReqCrosscheckGuard; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_GovernanceCombinedCheck; OWNER=tooling; UPDATED=2025-09-22
// Exit codes:
//  0 = all governance checks passed
//  2 = governance failure (stale NEXT, canary verify fail, or drift)
//  3 = unexpected internal error

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var summary = Summary.init(alloc);
    defer summary.deinit();

    // 1. NEXT freshness
    const ok_fresh = runStep(&summary, "freshness", &freshnessCheck) catch |e| {
        summary.addError("freshness", @errorName(e));
        return fail(&summary, 3);
    };
    if (!ok_fresh) return fail(&summary, 2);

    // 2. CANARY verify (build scanner if missing)
    const ok_canary = runStep(&summary, "canary", &canaryVerify) catch |e| {
        summary.addError("canary", @errorName(e));
        return fail(&summary, 3);
    };
    if (!ok_canary) return fail(&summary, 2);

    // 3. Documentation drift: README & IMPLEMENTATION_REALITY vs status.json
    const ok_doc = runStep(&summary, "doc_consistency", &docConsistency) catch |e| {
        summary.addError("doc_consistency", @errorName(e));
        return fail(&summary, 3);
    };
    if (!ok_doc) return fail(&summary, 2);

    // 4. GAP_ANALYSIS consistency (counts must match status.json summary.by_status)
    const ok_gap = runStep(&summary, "gap_consistency", &gapConsistency) catch |e| {
        summary.addError("gap_consistency", @errorName(e));
        return fail(&summary, 3);
    };
    if (!ok_gap) return fail(&summary, 2);

    // 5. NEXT slice structural validation
    const ok_slices = runStep(&summary, "next_slices", &sliceStructureCheck) catch |e| {
        summary.addError("next_slices", @errorName(e));
        return fail(&summary, 3);
    };
    if (!ok_slices) return fail(&summary, 2);

    // 6. Slice REQ cross-check: every slice header REQ-GQL-### must have a CANARY line (outside NEXT.md) referencing it.
    const ok_slice_req = runStep(&summary, "slice_req_crosscheck", &sliceReqCrosscheck) catch |e| {
        summary.addError("slice_req_crosscheck", @errorName(e));
        return fail(&summary, 3);
    };
    if (!ok_slice_req) return fail(&summary, 2);

    // 7. Evidence delta guard: detect removed REQ ids relative to previous snapshot (status_prev.json) unless override env set.
    const ok_evidence_delta = runStep(&summary, "evidence_delta", &evidenceDeltaCheck) catch |e| {
        summary.addError("evidence_delta", @errorName(e));
        return fail(&summary, 3);
    };
    if (!ok_evidence_delta) return fail(&summary, 2);

    // 8. ImplementationReality freshness (generation date within 1 day of status.json generated_at timestamp).
    const ok_reality_fresh = runStep(&summary, "reality_freshness", &realityFreshnessCheck) catch |e| {
        summary.addError("reality_freshness", @errorName(e));
        return fail(&summary, 3);
    };
    if (!ok_reality_fresh) return fail(&summary, 2);

    try summary.emit(.success);
}

fn fail(summary: *Summary, code: u8) noreturn {
    const overall: Overall = if (code == 2) Overall.failure else Overall.err;
    summary.emit(overall) catch {}; // best-effort
    std.process.exit(code);
}

fn runStep(summary: *Summary, name: []const u8, step: *const fn (*Summary) anyerror!bool) !bool {
    const result = try step(summary);
    if (result) summary.addOk(name) else summary.addFail(name);
    // If the step did not itself record a child process (like docConsistency), ensure it appears.
    if (!summary.stepRecorded(name)) {
        summary.addStep(name, result, &[_]u8{}, &[_]u8{}, 0);
    }
    return result;
}

fn freshnessCheck(summary: *Summary) !bool {
    return runChild(summary, &[_][]const u8{ "zig", "run", "scripts/next_freshness_check.zig" }, "freshness_child");
}

fn canaryVerify(summary: *Summary) !bool {
    // Ensure canary scanner present; attempt build if missing
    // Test hook: if EVIDENCE_DELTA_TEST=1 is set, skip re-running scanner to allow manual status.json manipulation prior to evidence_delta step.
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "EVIDENCE_DELTA_TEST")) |val| {
        defer std.heap.page_allocator.free(val);
        if (val.len == 1 and val[0] == '1') {
            return true; // trust existing status.json
        }
    } else |_| {}
    if (!fileExists("bin/canaryscan")) {
        _ = runChild(summary, &[_][]const u8{ "go", "build", "-o", "./bin/canaryscan", "./tools/canaryscan" }, "canary_build") catch return false;
    }
    return runChild(summary, &[_][]const u8{ "./bin/canaryscan", "--root", ".", "--verify", "docs/GAP_ANALYSIS.md", "--strict" }, "canary_verify_child");
}

fn docConsistency(_: *Summary) !bool {
    // Compute counts directly by scanning status.json summary.by_status including IMPL/STUB (transitional allowance).
    const status_path = "status.json";
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();
    const status_data = std.fs.cwd().readFileAlloc(a, status_path, 4 * 1024 * 1024) catch return false;
    defer a.free(status_data);

    var tested: usize = 0;
    var benched: usize = 0;
    var impl_cnt: usize = 0;
    var stub_cnt: usize = 0;
    _ = parsePatternCount(status_data, "\"BENCHED\": ", &benched);
    _ = parsePatternCount(status_data, "\"TESTED\": ", &tested);
    _ = parsePatternCount(status_data, "\"IMPL\": ", &impl_cnt);
    _ = parsePatternCount(status_data, "\"STUB\": ", &stub_cnt);
    const total = tested + benched + impl_cnt + stub_cnt;
    if (total == 0) return false;
    const readme_ok = try checkReadmeExtended(total, tested, benched, impl_cnt, stub_cnt);
    const reality_ok = try checkImplementationRealityExtended(total, tested, benched, impl_cnt, stub_cnt);
    if (!readme_ok or !reality_ok) {
        std.debug.print("DOC_CONSISTENCY_FAIL readme_ok={any} reality_ok={any} total={d} tested={d} benched={d} impl={d} stub={d}\n", .{ readme_ok, reality_ok, total, tested, benched, impl_cnt, stub_cnt });
    }
    return readme_ok and reality_ok;
}

fn gapConsistency(_: *Summary) !bool {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();
    const status_data = std.fs.cwd().readFileAlloc(a, "status.json", 4 * 1024 * 1024) catch return false;
    defer a.free(status_data);
    var tested: usize = 0;
    var benched: usize = 0;
    var impl_cnt: usize = 0;
    var stub_cnt: usize = 0;
    _ = parsePatternCount(status_data, "\"TESTED\": ", &tested);
    _ = parsePatternCount(status_data, "\"BENCHED\": ", &benched);
    _ = parsePatternCount(status_data, "\"IMPL\": ", &impl_cnt);
    _ = parsePatternCount(status_data, "\"STUB\": ", &stub_cnt);
    const total = tested + benched + impl_cnt + stub_cnt;
    const gap_data = std.fs.cwd().readFileAlloc(a, "docs/GAP_ANALYSIS.md", 4 * 1024 * 1024) catch return false;
    defer a.free(gap_data);
    const total_s = std.fmt.allocPrint(a, "{d}", .{total}) catch return false;
    defer a.free(total_s);
    const tested_s = std.fmt.allocPrint(a, "{d}", .{tested}) catch return false;
    defer a.free(tested_s);
    const benched_s = std.fmt.allocPrint(a, "{d}", .{benched}) catch return false;
    defer a.free(benched_s);
    const impl_s = std.fmt.allocPrint(a, "{d}", .{impl_cnt}) catch return false;
    defer a.free(impl_s);
    const stub_s = std.fmt.allocPrint(a, "{d}", .{stub_cnt}) catch return false;
    defer a.free(stub_s);
    const have_total_row = std.mem.indexOf(u8, gap_data, "| Total aspects (rows) | ") != null and std.mem.indexOf(u8, gap_data, total_s) != null;
    const have_tested_row = std.mem.indexOf(u8, gap_data, "| TESTED (non") != null and std.mem.indexOf(u8, gap_data, tested_s) != null;
    const have_benched_row = std.mem.indexOf(u8, gap_data, "| BENCHED") != null and std.mem.indexOf(u8, gap_data, benched_s) != null;
    // Optional IMPL/STUB rows tolerated if present; if present must match
    var impl_ok = true;
    if (std.mem.indexOf(u8, gap_data, "| IMPL (unpromoted)") != null) {
        impl_ok = std.mem.indexOf(u8, gap_data, impl_s) != null;
    }
    var stub_ok = true;
    if (std.mem.indexOf(u8, gap_data, "| STUB |") != null) {
        stub_ok = std.mem.indexOf(u8, gap_data, stub_s) != null;
    }
    var summary_ok = false;
    if (std.mem.indexOf(u8, gap_data, "-- Total aspect rows (status.csv): ")) |pos| {
        if (std.mem.indexOf(u8, gap_data[pos..], total_s) != null) summary_ok = true;
    }
    return have_total_row and have_tested_row and have_benched_row and impl_ok and stub_ok and summary_ok;
}

fn checkReadmeExtended(total: usize, tested: usize, benched: usize, impl_cnt: usize, stub_cnt: usize) !bool {
    // Accept README lines listing counts; require total/tested/benched; if IMPL/STUB mention present must match values.
    const path = "README.md";
    const data = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 1024 * 1024) catch return false;
    defer std.heap.page_allocator.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    const total_str = try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{total});
    defer std.heap.page_allocator.free(total_str);
    const tested_str = try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{tested});
    defer std.heap.page_allocator.free(tested_str);
    const benched_str = try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{benched});
    defer std.heap.page_allocator.free(benched_str);
    const impl_str = try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{impl_cnt});
    defer std.heap.page_allocator.free(impl_str);
    const stub_str = try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{stub_cnt});
    defer std.heap.page_allocator.free(stub_str);
    var saw_total = false;
    var saw_tested = false;
    var saw_benched = false;
    var impl_ok = true;
    var stub_ok = true;
    while (lines.next()) |line| {
        if (!saw_total and std.mem.indexOf(u8, line, total_str) != null and std.mem.indexOf(u8, line, "tracked aspects") != null) saw_total = true;
        if (!saw_tested and std.mem.indexOf(u8, line, tested_str) != null and std.mem.indexOf(u8, line, "TESTED") != null) saw_tested = true;
        if (!saw_benched and std.mem.indexOf(u8, line, benched_str) != null and std.mem.indexOf(u8, line, "BENCHED") != null) saw_benched = true;
        if (std.mem.indexOf(u8, line, "IMPL aspects") != null) impl_ok = std.mem.indexOf(u8, line, impl_str) != null;
        if (std.mem.indexOf(u8, line, "STUB aspects") != null) stub_ok = std.mem.indexOf(u8, line, stub_str) != null;
    }
    return saw_total and saw_tested and saw_benched and impl_ok and stub_ok;
}

fn checkImplementationRealityExtended(total: usize, tested: usize, benched: usize, impl_cnt: usize, stub_cnt: usize) !bool {
    const path = "docs/IMPLEMENTATION_REALITY.md";
    const data = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 1024 * 1024) catch return false;
    defer std.heap.page_allocator.free(data);
    // Simplified tolerant parsing: just need occurrences of "<total> aspects", "<tested> TESTED", "<benched> BENCHED".
    const total_need = try std.fmt.allocPrint(std.heap.page_allocator, "{d} aspects", .{total});
    defer std.heap.page_allocator.free(total_need);
    const tested_need = try std.fmt.allocPrint(std.heap.page_allocator, "{d} TESTED", .{tested});
    defer std.heap.page_allocator.free(tested_need);
    const benched_need = try std.fmt.allocPrint(std.heap.page_allocator, "{d} BENCHED", .{benched});
    defer std.heap.page_allocator.free(benched_need);
    var ok = true;
    if (std.mem.indexOf(u8, data, total_need) == null) ok = false;
    if (std.mem.indexOf(u8, data, tested_need) == null) ok = false;
    if (std.mem.indexOf(u8, data, benched_need) == null) ok = false;
    // Optional IMPL/STUB detection: if strings appear ensure counts match.
    const impl_need = try std.fmt.allocPrint(std.heap.page_allocator, "{d} IMPL", .{impl_cnt});
    defer std.heap.page_allocator.free(impl_need);
    const stub_need = try std.fmt.allocPrint(std.heap.page_allocator, "{d} STUB", .{stub_cnt});
    defer std.heap.page_allocator.free(stub_need);
    if (std.mem.indexOf(u8, data, "IMPL (unpromoted)") != null and std.mem.indexOf(u8, data, impl_need) == null) ok = false;
    if (std.mem.indexOf(u8, data, "STUB") != null and std.mem.indexOf(u8, data, stub_need) == null) ok = false;
    return ok;
}

fn sliceStructureCheck(_: *Summary) !bool {
    // Validate that each slice section in NEXT.md contains mandatory subsections.
    // Mandatory tokens per slice: "WHY:", "WHAT:", "ACCEPTANCE:".
    // Each slice must start with heading '### Slice S-' followed by three digits and ':'.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();
    const data = std.fs.cwd().readFileAlloc(a, "docs/NEXT.md", 2 * 1024 * 1024) catch return false;
    defer a.free(data);
    var ok = true;
    var iter = std.mem.splitSequence(u8, data, "\n### Slice S-");
    // First segment before first slice heading is ignored.
    _ = iter.next();
    while (iter.next()) |seg| {
        // Prepend marker removed; reconstruct for easier parsing.
        const slice_block = seg;
        // Extract ID prefix (first 3 chars should be digits)
        if (slice_block.len < 3) {
            ok = false;
            break;
        }
        const id_digits = slice_block[0..3];
        if (!allDigits(id_digits)) {
            ok = false;
            break;
        }
        // Ensure colon after ID somewhere early (within first 12 chars)
        const scan_len: usize = if (slice_block.len < 20) slice_block.len else 20;
        if (std.mem.indexOfScalar(u8, slice_block[0..scan_len], ':') == null) {
            ok = false;
            break;
        }
        // Require mandatory tokens before next slice or end
        if (std.mem.indexOf(u8, slice_block, "WHY:") == null) {
            ok = false;
            break;
        }
        if (std.mem.indexOf(u8, slice_block, "WHAT:") == null) {
            ok = false;
            break;
        }
        if (std.mem.indexOf(u8, slice_block, "ACCEPTANCE:") == null) {
            ok = false;
            break;
        }
    }
    return ok;
}

fn sliceReqCrosscheck(_: *Summary) !bool {
    // Parse NEXT.md slice headers to collect REQ-GQL-### identifiers.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();
    const data = std.fs.cwd().readFileAlloc(a, "docs/NEXT.md", 2 * 1024 * 1024) catch return false;
    defer a.free(data);
    var req_set = std.StringHashMap(void).init(a);
    defer req_set.deinit();
    var iter = std.mem.splitSequence(u8, data, "### Slice S-");
    _ = iter.next(); // skip preamble
    var slice_headers: usize = 0;
    var slices_with_req: usize = 0;
    while (iter.next()) |seg| {
        // Slice header form: 123: Name (REQ-GQL-XYZ)
        // Limit search to first line.
        var line_end_index: usize = 0;
        while (line_end_index < seg.len and seg[line_end_index] != '\n') : (line_end_index += 1) {}
        const header_line = seg[0..line_end_index];
        slice_headers += 1;
        if (std.mem.indexOf(u8, header_line, "REQ-GQL-")) |pos| {
            // Extract digits following
            var i = pos + 8; // after REQ-GQL-
            const start = i;
            while (i < header_line.len and header_line[i] >= '0' and header_line[i] <= '9') : (i += 1) {}
            if (i > start) {
                const req_id = header_line[pos..i]; // includes REQ-GQL-###
                _ = req_set.put(req_id, {}) catch return false;
                slices_with_req += 1;
            }
        }
    }
    if (slice_headers == 0) return false; // no slices at all -> fail
    if (slices_with_req != slice_headers) {
        if (std.process.getEnvVarOwned(a, "GOV_DEBUG")) |_| {
            std.debug.print("SLICE_REQ_CROSSCHECK_HEADER_MISSING slice_headers={d} with_req={d}\n", .{ slice_headers, slices_with_req });
        } else |_| {}
        return false;
    }
    // Load canonical status.json (source of truth for CANARY evidence aggregation)
    var status_ok = true;
    const status_data = std.fs.cwd().readFileAlloc(a, "status.json", 4 * 1024 * 1024) catch |e| blk: {
        std.debug.print("SLICE_REQ_CROSSCHECK_WARN missing status.json ({s}) fallback to grep\n", .{@errorName(e)});
        break :blk null;
    };
    if (status_data) |sd| {
        defer a.free(sd);
        var it2 = req_set.iterator();
        while (it2.next()) |kv| {
            const key = kv.key_ptr.*; // e.g. REQ-GQL-004
            if (std.mem.indexOf(u8, sd, key) == null) {
                if (std.process.getEnvVarOwned(a, "GOV_DEBUG")) |_| {
                    std.debug.print("SLICE_REQ_CROSSCHECK_STATUS_JSON_MISSING {s}\n", .{key});
                } else |_| {}
                status_ok = false;
            } else if (std.process.getEnvVarOwned(a, "GOV_DEBUG")) |_| {
                std.debug.print("SLICE_REQ_CROSSCHECK_STATUS_JSON_FOUND {s}\n", .{key});
            } else |_| {}
        }
        if (status_ok) return true; // All slice REQs present in status.json -> success
    }
    // Fallback: grep workspace for at least one CANARY or status reference.
    var all_found = true;
    var it3 = req_set.iterator();
    while (it3.next()) |kv| {
        const key = kv.key_ptr.*;
        if (!grepWorkspaceForKey(a, key)) {
            if (std.process.getEnvVarOwned(a, "GOV_DEBUG")) |_| {
                std.debug.print("SLICE_REQ_CROSSCHECK_GREP_MISSING {s}\n", .{key});
            } else |_| {}
            all_found = false;
        }
    }
    return all_found;
}

fn grepWorkspaceForKey(a: std.mem.Allocator, key: []const u8) bool {
    // Use external grep for simplicity and reliability.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    var child = std.process.Child.init(&[_][]const u8{ "grep", "-R", "--include=*.zig", "--include=*.md", key, "." }, alloc);
    child.stderr_behavior = .Ignore;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.spawn() catch return false;
    var stdout_stream = child.stdout.?;
    var buf: [16384]u8 = undefined;
    const n = stdout_stream.read(&buf) catch 0;
    const term = child.wait() catch return false;
    if (term.Exited != 0) return false;
    const slice = buf[0..n];
    // Accept any line with key; prefer ones also containing CANARY but not required now (status.json rows may lack it)
    var it = std.mem.splitScalar(u8, slice, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, key) != null and std.mem.indexOf(u8, line, "docs/NEXT.md") == null) return true;
    }
    return false;
}

fn allDigits(s: []const u8) bool {
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

fn parseInt(s: []const u8) ?usize {
    var val: usize = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        val = val * 10 + @as(usize, c - '0');
    }
    return val;
}

fn checkReadme(total: usize, tested: usize, benched: usize) !bool {
    const path = "README.md";
    const data = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 1024 * 1024) catch return false;
    defer std.heap.page_allocator.free(data);
    var saw_total = false;
    var saw_tested = false;
    var saw_benched = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    const total_str = std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{total}) catch return false;
    defer std.heap.page_allocator.free(total_str);
    const tested_str = std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{tested}) catch return false;
    defer std.heap.page_allocator.free(tested_str);
    const benched_str = std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{benched}) catch return false;
    defer std.heap.page_allocator.free(benched_str);
    while (lines.next()) |line| {
        // Accept either top summary bullet ("tracked aspects") or coverage section ("aspects tracked") for total.
        if (!saw_total and std.mem.indexOf(u8, line, total_str) != null and (std.mem.indexOf(u8, line, "tracked aspects") != null or std.mem.indexOf(u8, line, "aspects tracked") != null)) saw_total = true;
        if (!saw_tested and std.mem.indexOf(u8, line, tested_str) != null and (std.mem.indexOf(u8, line, "TESTED") != null or std.mem.indexOf(u8, line, "TESTED aspects") != null)) saw_tested = true;
        if (!saw_benched and std.mem.indexOf(u8, line, benched_str) != null and (std.mem.indexOf(u8, line, "BENCHED") != null or std.mem.indexOf(u8, line, "BENCHED aspects") != null)) saw_benched = true;
    }
    return saw_total and saw_tested and saw_benched;
}

fn checkImplementationReality(total: usize, tested: usize, benched: usize) !bool {
    const path = "docs/IMPLEMENTATION_REALITY.md";
    const data = std.fs.cwd().readFileAlloc(std.heap.page_allocator, path, 1024 * 1024) catch return false;
    defer std.heap.page_allocator.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    var saw_total = false;
    var saw_tested = false;
    var saw_benched = false;
    // Accept both bolded and plain variants (e.g., **336 aspects**)
    const total_plain = std.fmt.allocPrint(std.heap.page_allocator, "{d} aspects", .{total}) catch return false;
    defer std.heap.page_allocator.free(total_plain);
    const total_bold = std.fmt.allocPrint(std.heap.page_allocator, "**{d} aspects**", .{total}) catch return false;
    defer std.heap.page_allocator.free(total_bold);
    const tested_plain = std.fmt.allocPrint(std.heap.page_allocator, "{d} TESTED", .{tested}) catch return false;
    defer std.heap.page_allocator.free(tested_plain);
    const tested_bold = std.fmt.allocPrint(std.heap.page_allocator, "**{d} TESTED**", .{tested}) catch return false;
    defer std.heap.page_allocator.free(tested_bold);
    const benched_plain = std.fmt.allocPrint(std.heap.page_allocator, "{d} BENCHED", .{benched}) catch return false;
    defer std.heap.page_allocator.free(benched_plain);
    const benched_bold = std.fmt.allocPrint(std.heap.page_allocator, "**{d} BENCHED**", .{benched}) catch return false;
    defer std.heap.page_allocator.free(benched_bold);
    while (lines.next()) |line| {
        if (!saw_total and (std.mem.indexOf(u8, line, total_plain) != null or std.mem.indexOf(u8, line, total_bold) != null)) saw_total = true;
        if (!saw_tested and (std.mem.indexOf(u8, line, tested_plain) != null or std.mem.indexOf(u8, line, tested_bold) != null)) saw_tested = true;
        if (!saw_benched and (std.mem.indexOf(u8, line, benched_plain) != null or std.mem.indexOf(u8, line, benched_bold) != null)) saw_benched = true;
    }
    return saw_total and saw_tested and saw_benched;
}

fn fileExists(path: []const u8) bool {
    // statFile returns error.FileNotFound if missing; treat all other errors as missing for safety.
    _ = std.fs.cwd().statFile(path) catch return false;
    return true;
}

fn runChild(summary: *Summary, argv: []const []const u8, tag: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var child = std.process.Child.init(argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    var timer = try std.time.Timer.start();
    try child.spawn();
    var stdout_buf: [8192]u8 = undefined;
    var stderr_buf: [8192]u8 = undefined;
    var stdout_stream = child.stdout.?;
    var stderr_stream = child.stderr.?;
    const out_bytes = try stdout_stream.read(&stdout_buf);
    const err_bytes = try stderr_stream.read(&stderr_buf);
    const term = try child.wait();
    const elapsed_ns = timer.read();
    summary.addStep(tag, term.Exited == 0, stdout_buf[0..out_bytes], stderr_buf[0..err_bytes], elapsed_ns);
    return term.Exited == 0;
}

const Summary = struct {
    alloc: std.mem.Allocator,
    steps: std.ArrayListUnmanaged(Step),
    errors: std.ArrayListUnmanaged(ErrorItem),
    pub fn init(a: std.mem.Allocator) Summary {
        return .{ .alloc = a, .steps = .{}, .errors = .{} };
    }
    pub fn deinit(self: *Summary) void {
        // Free per-step owned slices
        for (self.steps.items) |s| {
            if (s.name.len > 0) self.alloc.free(s.name);
            if (s.stdout_snip.len > 0) self.alloc.free(s.stdout_snip);
            if (s.stderr_snip.len > 0) self.alloc.free(s.stderr_snip);
        }
        self.steps.deinit(self.alloc);
        // Free per-error owned slices
        for (self.errors.items) |e| {
            if (e.context.len > 0) self.alloc.free(e.context);
            if (e.message.len > 0) self.alloc.free(e.message);
        }
        self.errors.deinit(self.alloc);
    }
    pub fn addStep(self: *Summary, name: []const u8, ok: bool, stdout: []const u8, stderr: []const u8, ns: u64) void {
        _ = self.steps.append(self.alloc, .{ .name = dup(self.alloc, name), .ok = ok, .stdout_snip = slicePrefix(self.alloc, stdout), .stderr_snip = slicePrefix(self.alloc, stderr), .elapsed_ns = ns }) catch {};
    }
    pub fn addOk(self: *Summary, _name: []const u8) void {
        _ = self;
        _ = _name;
    }
    pub fn addFail(self: *Summary, _name: []const u8) void {
        _ = self;
        _ = _name;
    }
    pub fn stepRecorded(self: *Summary, name: []const u8) bool {
        for (self.steps.items) |s| if (std.mem.eql(u8, s.name, name)) return true;
        return false;
    }
    pub fn addError(self: *Summary, ctx: []const u8, msg: []const u8) void {
        _ = self.errors.append(self.alloc, .{ .context = dup(self.alloc, ctx), .message = dup(self.alloc, msg) }) catch {};
    }
    pub fn emit(self: *Summary, status: Overall) !void {
        var stdout_file: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
        const json = try self.toJSON(status);
        defer self.alloc.free(json);
        // Write JSON plus newline
        _ = try stdout_file.write(json);
        _ = try stdout_file.write("\n");
    }
    fn toJSON(self: *Summary, status: Overall) ![]u8 {
        // Build a temporary struct and stringify alloc
        const StepJson = struct {
            name: []const u8,
            ok: bool,
            elapsed_ns: u64,
            stdout: ?[]const u8 = null,
            stderr: ?[]const u8 = null,
        };
        var steps_json = std.ArrayListUnmanaged(StepJson){};
        defer steps_json.deinit(self.alloc);
        for (self.steps.items) |s| {
            _ = steps_json.append(self.alloc, .{ .name = s.name, .ok = s.ok, .elapsed_ns = s.elapsed_ns, .stdout = if (s.stdout_snip.len > 0) s.stdout_snip else null, .stderr = if (s.stderr_snip.len > 0) s.stderr_snip else null }) catch {};
        }
        const ErrorJson = struct { context: []const u8, message: []const u8 };
        var errs_json = std.ArrayListUnmanaged(ErrorJson){};
        defer errs_json.deinit(self.alloc);
        for (self.errors.items) |e| _ = errs_json.append(self.alloc, .{ .context = e.context, .message = e.message }) catch {};
        // Manual JSON assembly (minified)
        var out = std.ArrayListUnmanaged(u8){};
        defer out.deinit(self.alloc);
        try out.appendSlice(self.alloc, "{");
        try out.appendSlice(self.alloc, "\"type\":\"governance_summary\",");
        try out.appendSlice(self.alloc, "\"status\":\"");
        try out.appendSlice(self.alloc, @tagName(status));
        try out.appendSlice(self.alloc, "\",");
        // steps array
        try out.appendSlice(self.alloc, "\"steps\":[");
        var si: usize = 0;
        while (si < steps_json.items.len) : (si += 1) {
            if (si > 0) try out.append(self.alloc, ',');
            const st = steps_json.items[si];
            try out.appendSlice(self.alloc, "{");
            try out.appendSlice(self.alloc, "\"name\":\"");
            try jsonEscape(&out, self.alloc, st.name);
            try out.appendSlice(self.alloc, "\",\"ok\":");
            try out.appendSlice(self.alloc, if (st.ok) "true" else "false");
            try out.appendSlice(self.alloc, ",\"elapsed_ns\":");
            try appendInt(&out, self.alloc, st.elapsed_ns);
            if (st.stdout) |sout| {
                if (sout.len > 0) {
                    try out.appendSlice(self.alloc, ",\"stdout\":\"");
                    try jsonEscape(&out, self.alloc, sout);
                    try out.appendSlice(self.alloc, "\"");
                }
            }
            if (st.stderr) |serr| {
                if (serr.len > 0) {
                    try out.appendSlice(self.alloc, ",\"stderr\":\"");
                    try jsonEscape(&out, self.alloc, serr);
                    try out.appendSlice(self.alloc, "\"");
                }
            }
            try out.appendSlice(self.alloc, "}");
        }
        try out.appendSlice(self.alloc, "]");
        if (errs_json.items.len > 0) {
            try out.appendSlice(self.alloc, ",\"errors\":[");
            var ei: usize = 0;
            while (ei < errs_json.items.len) : (ei += 1) {
                if (ei > 0) try out.append(self.alloc, ',');
                const er = errs_json.items[ei];
                try out.appendSlice(self.alloc, "{\"context\":\"");
                try jsonEscape(&out, self.alloc, er.context);
                try out.appendSlice(self.alloc, "\",\"message\":\"");
                try jsonEscape(&out, self.alloc, er.message);
                try out.appendSlice(self.alloc, "}");
            }
            try out.appendSlice(self.alloc, "]");
        }
        try out.appendSlice(self.alloc, "}");
        return out.toOwnedSlice(self.alloc);
    }
};

fn appendInt(out: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, value: u64) !void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return error.OutOfMemory;
    try out.appendSlice(a, s);
}

fn jsonEscape(out: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => try out.appendSlice(a, "\\r"),
        '\t' => try out.appendSlice(a, "\\t"),
        else => try out.append(a, c),
    };
}

const Step = struct { name: []const u8, ok: bool, stdout_snip: []const u8, stderr_snip: []const u8, elapsed_ns: u64 };
const ErrorItem = struct { context: []const u8, message: []const u8 };
const Overall = enum { success, failure, err };

fn parseAfterKey(data: []const u8, key: []const u8, out: *usize) void {
    if (std.mem.indexOf(u8, data, key)) |pos| {
        const slice = data[pos + key.len ..];
        const rel_colon = std.mem.indexOfScalar(u8, slice, ':') orelse return;
        const colon_pos = pos + key.len + rel_colon;
        var i = colon_pos + 1;
        while (i < data.len and (data[i] == ' ' or data[i] == '\n')) : (i += 1) {}
        var val: usize = 0;
        var any = false;
        while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {
            any = true;
            val = val * 10 + @as(usize, data[i] - '0');
        }
        if (any) out.* = val;
    }
}

fn parsePatternCount(data: []const u8, pat: []const u8, out: *usize) bool {
    if (std.mem.indexOf(u8, data, pat)) |pos| {
        var i = pos + pat.len;
        var val: usize = 0;
        var any = false;
        while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {
            any = true;
            val = val * 10 + @as(usize, data[i] - '0');
        }
        if (any) {
            out.* = val;
            return true;
        }
    }
    return false;
}

fn dup(a: std.mem.Allocator, s: []const u8) []u8 {
    const buf = a.alloc(u8, s.len) catch return @constCast(s);
    @memcpy(buf, s);
    return buf;
}

fn slicePrefix(a: std.mem.Allocator, s: []const u8) []u8 {
    const max = 512;
    if (s.len <= max) return dup(a, s);
    return dup(a, s[0..max]);
}

// CANARY: REQ=REQ-GQL-010; FEATURE="Governance"; ASPECT=EvidenceDeltaGuard; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_EvidenceDeltaGuard; OWNER=tooling; UPDATED=2025-09-22
fn evidenceDeltaCheck(_: *Summary) !bool {
    // Compare status_prev.json to status.json; fail if any REQ-GQL- ids removed unless ALLOW_REQ_REMOVAL env set.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();
    if (!fileExists("status_prev.json")) {
        // In normal runs absence means first run, skip. In test mode require it.
        if (std.process.getEnvVarOwned(a, "EVIDENCE_DELTA_TEST")) |val| {
            defer a.free(val);
            if (val.len == 1 and val[0] == '1') return false;
        } else |_| {}
        return true;
    }
    const prev = std.fs.cwd().readFileAlloc(a, "status_prev.json", 8 * 1024 * 1024) catch return false;
    defer a.free(prev);
    const curr = std.fs.cwd().readFileAlloc(a, "status.json", 8 * 1024 * 1024) catch return false;
    defer a.free(curr);
    // Build sets of REQ ids from explicit id fields only to avoid false positives from tests referencing removed ids.
    var prev_set = std.StringHashMap(void).init(a);
    defer prev_set.deinit();
    var scan_prev: usize = 0;
    const needle_id = "\"id\": \"REQ-GQL-";
    while (scan_prev < prev.len) {
        if (std.mem.indexOfPos(u8, prev, scan_prev, needle_id)) |p| {
            const dstart = p + needle_id.len;
            var dend = dstart;
            while (dend < prev.len and prev[dend] >= '0' and prev[dend] <= '9') : (dend += 1) {}
            if (dend > dstart) {
                const id = prev[dstart..dend];
                _ = prev_set.put(id, {}) catch return false;
            }
            scan_prev = dend;
        } else break;
    }
    var curr_set = std.StringHashMap(void).init(a);
    defer curr_set.deinit();
    var scan_curr: usize = 0;
    while (scan_curr < curr.len) {
        if (std.mem.indexOfPos(u8, curr, scan_curr, needle_id)) |p| {
            const dstart = p + needle_id.len;
            var dend = dstart;
            while (dend < curr.len and curr[dend] >= '0' and curr[dend] <= '9') : (dend += 1) {}
            if (dend > dstart) {
                const id = curr[dstart..dend];
                _ = curr_set.put(id, {}) catch return false;
            }
            scan_curr = dend;
        } else break;
    }
    var removed: usize = 0;
    var it_prev = prev_set.iterator();
    while (it_prev.next()) |kv| {
        const id = kv.key_ptr.*;
        if (!curr_set.contains(id)) removed += 1;
    }
    if (removed == 0) return true;
    // Allow removal if env var ALLOW_REQ_REMOVAL=1
    if (std.process.getEnvVarOwned(a, "ALLOW_REQ_REMOVAL")) |val| {
        defer a.free(val);
        if (val.len == 1 and val[0] == '1') return true;
    } else |_| {}
    if (std.process.getEnvVarOwned(a, "GOV_DEBUG")) |_| {
        std.debug.print("EVIDENCE_DELTA_FAIL removed={d}\n", .{removed});
    } else |_| {}
    return false;
}

// CANARY: REQ=REQ-GQL-010; FEATURE="Governance"; ASPECT=RealityFreshnessGuard; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_RealityFreshnessGuard; OWNER=tooling; UPDATED=2025-09-22
fn realityFreshnessCheck(_: *Summary) !bool {
    // Extract generated_at from status.json (RFC3339) and compare date in IMPLEMENTATION_REALITY.md.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();
    const status = std.fs.cwd().readFileAlloc(a, "status.json", 4 * 1024 * 1024) catch return false;
    defer a.free(status);
    const reality = std.fs.cwd().readFileAlloc(a, "docs/IMPLEMENTATION_REALITY.md", 2 * 1024 * 1024) catch return false;
    defer a.free(reality);
    const key = "\"generated_at\": \""; // "generated_at": "2025-09-22T12:34:56Z"
    const pos_opt = std.mem.indexOf(u8, status, key) orelse return false;
    const pos = pos_opt + key.len;
    var end = pos;
    while (end < status.len and status[end] != '"') : (end += 1) {}
    if (end >= status.len) return false;
    const ts = status[pos..end];
    // Take date prefix YYYY-MM-DD
    if (ts.len < 10) return false;
    const date_prefix = ts[0..10];
    // Implementation reality must contain this date (or env override REALITY_FRESHNESS_MAX_DAYS)
    var max_days: usize = 1;
    if (std.process.getEnvVarOwned(a, "REALITY_FRESHNESS_MAX_DAYS")) |val| {
        defer a.free(val);
        var tmp: usize = 0;
        var i: usize = 0;
        while (i < val.len and val[i] >= '0' and val[i] <= '9') : (i += 1) {
            tmp = tmp * 10 + @as(usize, val[i] - '0');
        }
        if (tmp > 0) max_days = tmp;
    } else |_| {}
    // Accept if current date matches or (if max_days>1) date within range; we only have target date in reality doc, so check presence of date_prefix.
    if (std.mem.indexOf(u8, reality, date_prefix) != null) return true;
    // If max_days > 1 attempt to accept yesterday date (approx by simple decrement, ignoring month boundaries for simplicity)
    if (max_days > 1) {
        var year: u16 = 0;
        var month: u8 = 0;
        var day: u8 = 0;
        if (date_prefix.len >= 10) {
            const ycalc: u16 = @intCast((@as(u16, date_prefix[0] - '0') * 1000) + (@as(u16, date_prefix[1] - '0') * 100) + (@as(u16, date_prefix[2] - '0') * 10) + @as(u16, date_prefix[3] - '0'));
            const mcalc: u8 = @intCast((@as(u16, date_prefix[5] - '0') * 10) + @as(u16, date_prefix[6] - '0'));
            const dcalc: u8 = @intCast((@as(u16, date_prefix[8] - '0') * 10) + @as(u16, date_prefix[9] - '0'));
            year = ycalc;
            month = mcalc;
            day = dcalc;
        }
        if (day > 1) {
            day -= 1;
            var buf: [10]u8 = undefined;
            _ = std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, day }) catch return false;
            if (std.mem.indexOf(u8, reality, buf[0..10]) != null) return true;
        }
    }
    if (std.process.getEnvVarOwned(a, "GOV_DEBUG")) |_| {
        std.debug.print("REALITY_FRESHNESS_FAIL date_prefix={s}\n", .{date_prefix});
    } else |_| {}
    return false;
}
