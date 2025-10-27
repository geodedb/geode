const std = @import("std");
const testing = std.testing;
const vk_compute = @import("vulkan_compute");
const vk = @import("vulkan_loader");

// Simple hand-written SPIR-V for vector addition (testing only)
// This is the compiled version of vector_add.comp
const vector_add_spirv = [_]u32{
    0x07230203, 0x00010000, 0x0008000a, 0x0000002e, 0x00000000, 0x00020011, 0x00000001, 0x0006000b,
    0x00000001, 0x4c534c47, 0x6474732e, 0x3035342e, 0x00000000, 0x0003000e, 0x00000000, 0x00000001,
    0x0006000f, 0x00000005, 0x00000004, 0x6e69616d, 0x00000000, 0x0000000b, 0x00060010, 0x00000004,
    0x00000011, 0x00000100, 0x00000001, 0x00000001, 0x00030003, 0x00000002, 0x000001c2, 0x00040005,
    0x00000004, 0x6e69616d, 0x00000000, 0x00050005, 0x00000009, 0x00786469, 0x00000000, 0x00000000,
    0x00080005, 0x0000000b, 0x475f6c67, 0x61626f6c, 0x766e496c, 0x7461636f, 0x496e6f69, 0x00000044,
    0x00050005, 0x00000014, 0x7074754f, 0x00007475, 0x00000000, 0x00060005, 0x00000016, 0x61746164,
    0x74756f5f, 0x00000000, 0x00000000, 0x00050005, 0x0000001b, 0x75706e49, 0x00004174, 0x00000000,
    0x00050005, 0x0000001c, 0x61746164, 0x0000615f, 0x00000000, 0x00050005, 0x00000025, 0x75706e49,
    0x00004274, 0x00000000, 0x00050005, 0x00000026, 0x61746164, 0x0000625f, 0x00000000, 0x00040047,
    0x0000000b, 0x0000000b, 0x0000001c, 0x00040047, 0x00000015, 0x00000006, 0x00000004, 0x00050048,
    0x00000014, 0x00000000, 0x00000023, 0x00000000, 0x00030047, 0x00000014, 0x00000003, 0x00040047,
    0x00000016, 0x00000022, 0x00000000, 0x00040047, 0x00000016, 0x00000021, 0x00000002, 0x00040047,
    0x0000001a, 0x00000006, 0x00000004, 0x00050048, 0x0000001b, 0x00000000, 0x00000023, 0x00000000,
    0x00030047, 0x0000001b, 0x00000003, 0x00040047, 0x0000001c, 0x00000022, 0x00000000, 0x00040047,
    0x0000001c, 0x00000021, 0x00000000, 0x00040047, 0x00000024, 0x00000006, 0x00000004, 0x00050048,
    0x00000025, 0x00000000, 0x00000023, 0x00000000, 0x00030047, 0x00000025, 0x00000003, 0x00040047,
    0x00000026, 0x00000022, 0x00000000, 0x00000047, 0x00000026, 0x00000021, 0x00000001, 0x00020013,
    0x00000002, 0x00030021, 0x00000003, 0x00000002, 0x00040015, 0x00000006, 0x00000020, 0x00000000,
    0x00040020, 0x00000007, 0x00000007, 0x00000006, 0x00040017, 0x00000008, 0x00000006, 0x00000003,
    0x00040020, 0x0000000a, 0x00000001, 0x00000008, 0x0004003b, 0x0000000a, 0x0000000b, 0x00000001,
    0x00040015, 0x0000000c, 0x00000020, 0x00000001, 0x0004002b, 0x0000000c, 0x0000000d, 0x00000000,
    0x00040020, 0x0000000e, 0x00000001, 0x00000006, 0x00030016, 0x00000012, 0x00000020, 0x0003001d,
    0x00000013, 0x00000012, 0x0003001e, 0x00000014, 0x00000013, 0x00040020, 0x00000015, 0x00000002,
    0x00000014, 0x0004003b, 0x00000015, 0x00000016, 0x00000002, 0x00040020, 0x00000018, 0x00000002,
    0x00000012, 0x0003001d, 0x0000001a, 0x00000012, 0x0003001e, 0x0000001b, 0x0000001a, 0x00040020,
    0x0000001c, 0x00000002, 0x0000001b, 0x0004003b, 0x0000001c, 0x0000001c, 0x00000002, 0x0003001d,
    0x00000024, 0x00000012, 0x0003001e, 0x00000025, 0x00000024, 0x00040020, 0x00000026, 0x00000002,
    0x00000025, 0x0004003b, 0x00000026, 0x00000026, 0x00000002, 0x00050036, 0x00000002, 0x00000004,
    0x00000000, 0x00000003, 0x000200f8, 0x00000005, 0x0004003b, 0x00000007, 0x00000009, 0x00000007,
    0x00050041, 0x0000000e, 0x0000000f, 0x0000000b, 0x0000000d, 0x0004003d, 0x00000006, 0x00000010,
    0x0000000f, 0x0003003e, 0x00000009, 0x00000010, 0x0004003d, 0x00000006, 0x00000011, 0x00000009,
    0x0004003d, 0x00000006, 0x00000017, 0x00000009, 0x00060041, 0x00000018, 0x00000019, 0x00000016,
    0x0000000d, 0x00000017, 0x0004003d, 0x00000006, 0x0000001d, 0x00000009, 0x00060041, 0x00000018,
    0x0000001e, 0x0000001c, 0x0000000d, 0x0000001d, 0x0004003d, 0x00000012, 0x0000001f, 0x0000001e,
    0x0004003d, 0x00000006, 0x00000027, 0x00000009, 0x00060041, 0x00000018, 0x00000028, 0x00000026,
    0x0000000d, 0x00000027, 0x0004003d, 0x00000012, 0x00000029, 0x00000028, 0x00050081, 0x00000012,
    0x0000002a, 0x0000001f, 0x00000029, 0x0003003e, 0x00000019, 0x0000002a, 0x000100fd, 0x00010038,
};

test "Vulkan compute - device initialization" {
    const allocator = testing.allocator;

    var compute = vk_compute.VulkanCompute.init(allocator) catch |err| {
        if (err == vk_compute.VulkanError.InstanceCreationFailed) {
            std.debug.print("Vulkan not available, skipping test\n", .{});
            return error.SkipZigTest;
        }
        return err;
    };
    defer compute.deinit();

    // Verify device was initialized
    const device_name = compute.getDeviceName();
    std.debug.print("Vulkan device: {s}\n", .{device_name});

    try testing.expect(device_name.len > 0);
}

test "Vulkan compute - buffer creation and copy" {
    const allocator = testing.allocator;

    var compute = vk_compute.VulkanCompute.init(allocator) catch |err| {
        if (err == vk_compute.VulkanError.InstanceCreationFailed) {
            return error.SkipZigTest;
        }
        return err;
    };
    defer compute.deinit();

    // Create host-visible buffer
    const buffer_size = 1024;
    var buffer = try vk_compute.VulkanBuffer.create(
        &compute,
        buffer_size,
        vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        true, // host_visible
    );
    defer buffer.destroy();

    // Test data round-trip
    var test_data: [256]u8 = undefined;
    for (&test_data, 0..) |*byte, i| {
        byte.* = @intCast(i & 0xFF);
    }

    try buffer.copyFromHost(&test_data);

    var read_data: [256]u8 = undefined;
    try buffer.copyToHost(&read_data);

    try testing.expectEqualSlices(u8, &test_data, &read_data);
}

test "Vulkan compute - simple vector addition" {
    const allocator = testing.allocator;

    var compute = vk_compute.VulkanCompute.init(allocator) catch |err| {
        if (err == vk_compute.VulkanError.InstanceCreationFailed) {
            return error.SkipZigTest;
        }
        return err;
    };
    defer compute.deinit();

    // Create pipeline from embedded SPIR-V
    var pipeline = try vk_compute.ComputePipeline.createFromSPIRV(
        &compute,
        &vector_add_spirv,
        3, // 3 buffers: input_a, input_b, output
    );
    defer pipeline.destroy();

    // Prepare test data
    const n: usize = 1024;
    const float_size = @sizeOf(f32);
    const buffer_size = n * float_size;

    var input_a = try std.ArrayList(f32).initCapacity(allocator, n);
    defer input_a.deinit(allocator);
    var input_b = try std.ArrayList(f32).initCapacity(allocator, n);
    defer input_b.deinit(allocator);

    for (0..n) |i| {
        try input_a.append(allocator, @as(f32, @floatFromInt(i)));
        try input_b.append(allocator, @as(f32, @floatFromInt(i * 2)));
    }

    // Create buffers
    var buffer_a = try vk_compute.VulkanBuffer.create(
        &compute,
        buffer_size,
        vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        true,
    );
    defer buffer_a.destroy();

    var buffer_b = try vk_compute.VulkanBuffer.create(
        &compute,
        buffer_size,
        vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        true,
    );
    defer buffer_b.destroy();

    var buffer_out = try vk_compute.VulkanBuffer.create(
        &compute,
        buffer_size,
        vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        true,
    );
    defer buffer_out.destroy();

    // Copy input data
    const input_a_bytes = std.mem.sliceAsBytes(input_a.items);
    const input_b_bytes = std.mem.sliceAsBytes(input_b.items);

    try buffer_a.copyFromHost(input_a_bytes);
    try buffer_b.copyFromHost(input_b_bytes);

    // Execute kernel
    var buffers = [_]vk_compute.VulkanBuffer{ buffer_a, buffer_b, buffer_out };
    const workgroup_count = [3]u32{ @intCast(n / 256), 1, 1 };

    try pipeline.execute(&buffers, workgroup_count);

    // Read results
    const output = try allocator.alloc(f32, n);
    defer allocator.free(output);

    const output_bytes = std.mem.sliceAsBytes(output);
    try buffer_out.copyToHost(output_bytes);

    // Verify results
    for (0..n) |i| {
        const expected = input_a.items[i] + input_b.items[i];
        const actual = output[i];
        try testing.expectApproxEqAbs(expected, actual, 0.001);
    }

    std.debug.print("✅ Vulkan vector addition test passed ({} elements)\n", .{n});
}
