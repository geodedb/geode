"""Add allocation-free progress markers to Zig's unchanged test protocol."""

import json


def instrument(source, progress_path):
    start = "                const TestResults = std.zig.Server.Message.TestResults;"
    returned = "                testing.io_instance.deinit();"
    finished = "                try server.serveTestResults(.{"
    for anchor in (start, returned, finished):
        assert source.count(anchor) == 1, anchor
    source = source.replace(start, '                probeMark("start ", test_fn.name);\n' + start)
    source = source.replace(returned, '                probeMark("returned ", test_fn.name);\n' + returned)
    source = source.replace(finished, '                probeMark("finished ", test_fn.name);\n' + finished)
    # Linux diagnostic only. Raw libc writes avoid the I/O pool and the test
    # allocator, including around the existing fork-based regression tests.
    helper = r'''
const ProbeC = struct {
    extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
    extern "c" fn write(fd: c_int, buffer: [*]const u8, length: usize) isize;
    extern "c" fn close(fd: c_int) c_int;
};

fn probeMark(event: []const u8, name: []const u8) void {
    const fd = ProbeC.open(PROGRESS_PATH, 1089, @as(c_uint, 0o600));
    if (fd < 0) return;
    defer _ = ProbeC.close(fd);
    _ = ProbeC.write(fd, event.ptr, event.len);
    _ = ProbeC.write(fd, name.ptr, name.len);
    _ = ProbeC.write(fd, "\n", 1);
}
'''
    return source + helper.replace("PROGRESS_PATH", json.dumps(str(progress_path)))
