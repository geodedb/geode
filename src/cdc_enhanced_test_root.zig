// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6487: test root for src/streaming/cdc_enhanced.zig's inline tests
// (`test-cdc-enhanced`). Rooted at src/streaming/cdc_enhanced.zig the module
// could not reach src/client/host_port.zig, the shared address parser
// sinks/kafka_sink.zig now uses ("import of file outside module path"); from
// src/ it can. Test-only; never linked into the binary.

test {
    _ = @import("streaming/cdc_enhanced.zig");
}
