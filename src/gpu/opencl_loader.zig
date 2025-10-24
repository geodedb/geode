const std = @import("std");

pub const c = @cImport({
    @cInclude("CL/cl.h");
});

pub const OpenCL = struct {
    pub fn get_platform_ids(num_entries: u32, platforms: ?*c.cl_platform_id, num_platforms: ?*u32) c.cl_int {
        return c.clGetPlatformIDs(num_entries, platforms, num_platforms);
    }

    pub fn get_device_ids(platform: c.cl_platform_id, device_type: c.cl_device_type, num_entries: u32, devices: ?*c.cl_device_id, num_devices: ?*u32) c.cl_int {
        return c.clGetDeviceIDs(platform, device_type, num_entries, devices, num_devices);
    }

    pub fn get_device_name(device: c.cl_device_id, buf: [*]u8, buf_len: usize) c.cl_int {
        return c.clGetDeviceInfo(device, c.CL_DEVICE_NAME, @as(c.size_t, buf_len), buf, null);
    }

    pub fn create_context_from_devices(devices: ?*c.cl_device_id, num_devices: u32) c.cl_context {
        const errcode: ?*c.cl_int = null;
        return c.clCreateContext(null, num_devices, devices, null, null, errcode);
    }

    pub fn create_command_queue(ctx: c.cl_context, device: c.cl_device_id) c.cl_command_queue {
        var err: c.cl_int = 0;
        const q = c.clCreateCommandQueue(ctx, device, 0, &err);
        return q;
    }

    pub fn create_program_with_source(ctx: c.cl_context, src: []const u8) c.cl_program {
        const src_ptr = src.ptr;
        var length: c.size_t = src.len;
        var err: c.cl_int = 0;
        const prog = c.clCreateProgramWithSource(ctx, 1, &src_ptr, &length, &err);
        return prog;
    }

    pub fn build_program(prog: c.cl_program, device: c.cl_device_id) c.cl_int {
        return c.clBuildProgram(prog, 1, &device, null, null, null);
    }

    pub fn create_kernel(prog: c.cl_program, name: []const u8) c.cl_kernel {
        var err: c.cl_int = 0;
        return c.clCreateKernel(prog, name.ptr, &err);
    }

    pub fn create_buffer(ctx: c.cl_context, flags: c.cl_mem_flags, size: usize) c.cl_mem {
        var err: c.cl_int = 0;
        return c.clCreateBuffer(ctx, flags, @as(c.size_t, size), null, &err);
    }

    pub fn enqueue_write_buffer(q: c.cl_command_queue, buf: c.cl_mem, blocking: c.cl_bool, offset: usize, size: usize, ptr: ?*anyopaque) c.cl_int {
        return c.clEnqueueWriteBuffer(q, buf, blocking, @as(c.size_t, offset), @as(c.size_t, size), ptr, 0, null, null);
    }

    pub fn enqueue_read_buffer(q: c.cl_command_queue, buf: c.cl_mem, blocking: c.cl_bool, offset: usize, size: usize, ptr: ?*anyopaque) c.cl_int {
        return c.clEnqueueReadBuffer(q, buf, blocking, @as(c.size_t, offset), @as(c.size_t, size), ptr, 0, null, null);
    }

    pub fn enqueue_nd_range_kernel(q: c.cl_command_queue, k: c.cl_kernel, work_dim: c.cl_uint, global_work_size: ?*c.size_t, local_work_size: ?*c.size_t) c.cl_int {
        return c.clEnqueueNDRangeKernel(q, k, work_dim, null, global_work_size, local_work_size, 0, null, null);
    }

    pub fn finish(q: c.cl_command_queue) c.cl_int {
        return c.clFinish(q);
    }
};
