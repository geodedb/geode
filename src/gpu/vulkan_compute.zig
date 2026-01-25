const std = @import("std");
const Allocator = std.mem.Allocator;
const vk = @import("vulkan_loader.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-VULKAN-001; FEATURE="External Library Migration"; ASPECT=VulkanCompute; STATUS=IMPL; OWNER=core; UPDATED=2026-01-24
// External vulkan library integration for availability checking and future migration
// Current code maintains backward compatibility while exposing external library capabilities
const vulkan_lib = @import("vulkan");

/// Check if Vulkan is available using the external library
pub fn isVulkanAvailable() bool {
    return vulkan_lib.isAvailable();
}

/// Probe system for available Vulkan devices using external library
pub fn probeDevices(allocator: Allocator) vulkan_lib.ProbeResult {
    return vulkan_lib.probe(allocator);
}

pub const VulkanError = error{
    InstanceCreationFailed,
    NoPhysicalDevices,
    NoComputeQueue,
    DeviceCreationFailed,
    BufferCreationFailed,
    MemoryAllocationFailed,
    MemoryBindFailed,
    MemoryMapFailed,
    ShaderCreationFailed,
    PipelineCreationFailed,
    CommandPoolCreationFailed,
    CommandBufferAllocationFailed,
    CommandBufferBeginFailed,
    CommandBufferEndFailed,
    QueueSubmitFailed,
    DescriptorSetLayoutCreationFailed,
    DescriptorPoolCreationFailed,
    DescriptorSetAllocationFailed,
};

pub const VulkanCompute = struct {
    allocator: Allocator,
    instance: vk.VkInstance,
    physical_device: vk.VkPhysicalDevice,
    device: vk.VkDevice,
    queue: vk.VkQueue,
    queue_family_index: u32,
    command_pool: vk.VkCommandPool,
    memory_properties: vk.VkPhysicalDeviceMemoryProperties,
    device_properties: vk.VkPhysicalDeviceProperties,

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
        // Create Vulkan instance
        const app_info = vk.VkApplicationInfo{
            .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pNext = null,
            .pApplicationName = "Geode DB",
            .applicationVersion = vk.VK_API_VERSION_1_0,
            .pEngineName = "Geode",
            .engineVersion = vk.VK_API_VERSION_1_0,
            .apiVersion = vk.VK_API_VERSION_1_0,
        };

        const instance_create_info = vk.VkInstanceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .pApplicationInfo = &app_info,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = 0,
            .ppEnabledExtensionNames = null,
        };

        var instance: vk.VkInstance = undefined;
        var result = vk.Vulkan.createInstance(&instance_create_info, null, &instance);
        if (result != vk.VK_SUCCESS) {
            return VulkanError.InstanceCreationFailed;
        }

        // Enumerate physical devices
        var device_count: u32 = 0;
        result = vk.Vulkan.enumeratePhysicalDevices(instance, &device_count, null);
        if (result != vk.VK_SUCCESS or device_count == 0) {
            vk.Vulkan.destroyInstance(instance, null);
            return VulkanError.NoPhysicalDevices;
        }

        const physical_devices = try allocator.alloc(vk.VkPhysicalDevice, device_count);
        defer allocator.free(physical_devices);

        result = vk.Vulkan.enumeratePhysicalDevices(instance, &device_count, physical_devices.ptr);
        if (result != vk.VK_SUCCESS) {
            vk.Vulkan.destroyInstance(instance, null);
            return VulkanError.NoPhysicalDevices;
        }

        // Smart device selection: prefer discrete GPU, then by compute capability and memory
        var best_device: vk.VkPhysicalDevice = physical_devices[0];
        var best_score: i64 = -1;

        for (physical_devices) |dev| {
            var props: vk.VkPhysicalDeviceProperties = undefined;
            vk.Vulkan.getPhysicalDeviceProperties(dev, &props);

            var mem_props: vk.VkPhysicalDeviceMemoryProperties = undefined;
            vk.Vulkan.getPhysicalDeviceMemoryProperties(dev, &mem_props);

            // Calculate device score
            var score: i64 = 0;

            // Prefer discrete GPUs (highest priority)
            if (props.deviceType == vk.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) {
                score += 10000;
            } else if (props.deviceType == vk.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU) {
                score += 1000;
            } else if (props.deviceType == vk.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU) {
                score += 500;
            }

            // Check for compute queue support
            var qf_count: u32 = 0;
            vk.Vulkan.getPhysicalDeviceQueueFamilyProperties(dev, &qf_count, null);
            const temp_qf = allocator.alloc(vk.VkQueueFamilyProperties, qf_count) catch continue;
            defer allocator.free(temp_qf);
            vk.Vulkan.getPhysicalDeviceQueueFamilyProperties(dev, &qf_count, temp_qf.ptr);

            var has_compute = false;
            var max_compute_queues: u32 = 0;
            for (temp_qf) |family| {
                if ((family.queueFlags & vk.VK_QUEUE_COMPUTE_BIT) != 0) {
                    has_compute = true;
                    if (family.queueCount > max_compute_queues) {
                        max_compute_queues = family.queueCount;
                    }
                }
            }

            if (!has_compute) continue; // Skip devices without compute

            // Add score for compute queues (more is better for parallel workloads)
            score += @as(i64, max_compute_queues) * 10;

            // Add score for device memory (in 256MB chunks)
            var total_device_memory: u64 = 0;
            for (0..mem_props.memoryHeapCount) |i| {
                if ((mem_props.memoryHeaps[i].flags & vk.VK_MEMORY_HEAP_DEVICE_LOCAL_BIT) != 0) {
                    total_device_memory += mem_props.memoryHeaps[i].size;
                }
            }
            score += @as(i64, @intCast(total_device_memory / (256 * 1024 * 1024)));

            if (score > best_score) {
                best_score = score;
                best_device = dev;
            }
        }

        const physical_device = best_device;

        var device_properties: vk.VkPhysicalDeviceProperties = undefined;
        vk.Vulkan.getPhysicalDeviceProperties(physical_device, &device_properties);

        var memory_properties: vk.VkPhysicalDeviceMemoryProperties = undefined;
        vk.Vulkan.getPhysicalDeviceMemoryProperties(physical_device, &memory_properties);

        // Find compute queue family
        var queue_family_count: u32 = 0;
        vk.Vulkan.getPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, null);

        const queue_families = try allocator.alloc(vk.VkQueueFamilyProperties, queue_family_count);
        defer allocator.free(queue_families);

        vk.Vulkan.getPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, queue_families.ptr);

        var compute_queue_family: ?u32 = null;
        for (queue_families, 0..) |family, i| {
            if ((family.queueFlags & vk.VK_QUEUE_COMPUTE_BIT) != 0) {
                compute_queue_family = @intCast(i);
                break;
            }
        }

        if (compute_queue_family == null) {
            vk.Vulkan.destroyInstance(instance, null);
            return VulkanError.NoComputeQueue;
        }

        const queue_family_index = compute_queue_family.?;

        // Create logical device
        const queue_priorities = [_]f32{1.0};
        const queue_create_infos = [_]vk.VkDeviceQueueCreateInfo{
            .{
                .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .queueFamilyIndex = queue_family_index,
                .queueCount = 1,
                .pQueuePriorities = &queue_priorities,
            },
        };

        const device_create_info = vk.VkDeviceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_create_infos,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = 0,
            .ppEnabledExtensionNames = null,
            .pEnabledFeatures = null,
        };

        var device: vk.VkDevice = undefined;
        result = vk.Vulkan.createDevice(physical_device, &device_create_info, null, &device);
        if (result != vk.VK_SUCCESS) {
            vk.Vulkan.destroyInstance(instance, null);
            return VulkanError.DeviceCreationFailed;
        }

        // Get queue
        var queue: vk.VkQueue = undefined;
        vk.Vulkan.getDeviceQueue(device, queue_family_index, 0, &queue);

        // Create command pool
        const pool_create_info = vk.VkCommandPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = queue_family_index,
        };

        var command_pool: vk.VkCommandPool = undefined;
        result = vk.Vulkan.createCommandPool(device, &pool_create_info, null, &command_pool);
        if (result != vk.VK_SUCCESS) {
            vk.Vulkan.destroyDevice(device, null);
            vk.Vulkan.destroyInstance(instance, null);
            return VulkanError.CommandPoolCreationFailed;
        }

        return Self{
            .allocator = allocator,
            .instance = instance,
            .physical_device = physical_device,
            .device = device,
            .queue = queue,
            .queue_family_index = queue_family_index,
            .command_pool = command_pool,
            .memory_properties = memory_properties,
            .device_properties = device_properties,
        };
    }

    pub fn deinit(self: *Self) void {
        vk.Vulkan.destroyCommandPool(self.device, self.command_pool, null);
        vk.Vulkan.destroyDevice(self.device, null);
        vk.Vulkan.destroyInstance(self.instance, null);
    }

    pub fn getDeviceName(self: *const Self) []const u8 {
        const name_ptr: [*:0]const u8 = @ptrCast(&self.device_properties.deviceName);
        return std.mem.sliceTo(name_ptr, 0);
    }
};

pub const VulkanBuffer = struct {
    compute: *VulkanCompute,
    buffer: vk.VkBuffer,
    memory: vk.VkDeviceMemory,
    size: usize,
    host_visible: bool,

    const Self = @This();

    pub fn create(
        compute: *VulkanCompute,
        size: usize,
        usage: vk.VkBufferUsageFlags,
        host_visible: bool,
    ) !Self {
        // Create buffer
        const buffer_create_info = vk.VkBufferCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = size,
            .usage = usage,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };

        var buffer: vk.VkBuffer = undefined;
        var result = vk.Vulkan.createBuffer(compute.device, &buffer_create_info, null, &buffer);
        if (result != vk.VK_SUCCESS) {
            return VulkanError.BufferCreationFailed;
        }
        errdefer vk.Vulkan.destroyBuffer(compute.device, buffer, null);

        // Get memory requirements
        var mem_requirements: vk.VkMemoryRequirements = undefined;
        vk.Vulkan.getBufferMemoryRequirements(compute.device, buffer, &mem_requirements);

        // Find suitable memory type
        const memory_type_index = try findMemoryType(
            compute,
            mem_requirements.memoryTypeBits,
            if (host_visible)
                vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT
            else
                vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        );

        // Allocate memory
        const alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = memory_type_index,
        };

        var memory: vk.VkDeviceMemory = undefined;
        result = vk.Vulkan.allocateMemory(compute.device, &alloc_info, null, &memory);
        if (result != vk.VK_SUCCESS) {
            return VulkanError.MemoryAllocationFailed;
        }
        errdefer vk.Vulkan.freeMemory(compute.device, memory, null);

        // Bind buffer memory
        result = vk.Vulkan.bindBufferMemory(compute.device, buffer, memory, 0);
        if (result != vk.VK_SUCCESS) {
            return VulkanError.MemoryBindFailed;
        }

        return Self{
            .compute = compute,
            .buffer = buffer,
            .memory = memory,
            .size = size,
            .host_visible = host_visible,
        };
    }

    pub fn destroy(self: *Self) void {
        vk.Vulkan.freeMemory(self.compute.device, self.memory, null);
        vk.Vulkan.destroyBuffer(self.compute.device, self.buffer, null);
    }

    pub fn copyFromHost(self: *Self, data: []const u8) !void {
        if (!self.host_visible) {
            return error.BufferNotHostVisible;
        }

        if (data.len > self.size) {
            return error.DataTooLarge;
        }

        var mapped_ptr: ?*anyopaque = null;
        const result = vk.Vulkan.mapMemory(self.compute.device, self.memory, 0, self.size, 0, &mapped_ptr);
        if (result != vk.VK_SUCCESS) {
            return VulkanError.MemoryMapFailed;
        }

        const dest = @as([*]u8, @ptrCast(mapped_ptr))[0..data.len];
        @memcpy(dest, data);

        vk.Vulkan.unmapMemory(self.compute.device, self.memory);
    }

    pub fn copyToHost(self: *Self, data: []u8) !void {
        if (!self.host_visible) {
            return error.BufferNotHostVisible;
        }

        if (data.len > self.size) {
            return error.BufferTooSmall;
        }

        var mapped_ptr: ?*anyopaque = null;
        const result = vk.Vulkan.mapMemory(self.compute.device, self.memory, 0, self.size, 0, &mapped_ptr);
        if (result != vk.VK_SUCCESS) {
            return VulkanError.MemoryMapFailed;
        }

        const src = @as([*]const u8, @ptrCast(mapped_ptr))[0..data.len];
        @memcpy(data, src);

        vk.Vulkan.unmapMemory(self.compute.device, self.memory);
    }
};

pub const ComputePipeline = struct {
    compute: *VulkanCompute,
    shader_module: vk.VkShaderModule,
    descriptor_set_layout: vk.VkDescriptorSetLayout,
    pipeline_layout: vk.VkPipelineLayout,
    pipeline: vk.VkPipeline,
    descriptor_pool: vk.VkDescriptorPool,

    const Self = @This();

    pub fn createFromSPIRV(
        compute: *VulkanCompute,
        spirv_code: []const u32,
        descriptor_count: u32,
    ) !Self {
        // Create shader module
        const shader_create_info = vk.VkShaderModuleCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = spirv_code.len * @sizeOf(u32),
            .pCode = spirv_code.ptr,
        };

        var shader_module: vk.VkShaderModule = undefined;
        var result = vk.Vulkan.createShaderModule(compute.device, &shader_create_info, null, &shader_module);
        if (result != vk.VK_SUCCESS) {
            return VulkanError.ShaderCreationFailed;
        }
        errdefer vk.Vulkan.destroyShaderModule(compute.device, shader_module, null);

        // Create descriptor set layout
        const bindings = try compute.allocator.alloc(vk.VkDescriptorSetLayoutBinding, descriptor_count);
        defer compute.allocator.free(bindings);

        for (bindings, 0..) |*binding, i| {
            binding.* = vk.VkDescriptorSetLayoutBinding{
                .binding = @intCast(i),
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = 1,
                .stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT,
                .pImmutableSamplers = null,
            };
        }

        const layout_create_info = vk.VkDescriptorSetLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .bindingCount = descriptor_count,
            .pBindings = bindings.ptr,
        };

        var descriptor_set_layout: vk.VkDescriptorSetLayout = undefined;
        result = vk.Vulkan.createDescriptorSetLayout(compute.device, &layout_create_info, null, &descriptor_set_layout);
        if (result != vk.VK_SUCCESS) {
            return VulkanError.DescriptorSetLayoutCreationFailed;
        }
        errdefer vk.Vulkan.destroyDescriptorSetLayout(compute.device, descriptor_set_layout, null);

        // Create pipeline layout with push constants support
        const push_constant_ranges = [_]vk.VkPushConstantRange{
            .{
                .stageFlags = vk.VK_SHADER_STAGE_COMPUTE_BIT,
                .offset = 0,
                .size = 128, // Max 128 bytes for push constants
            },
        };

        const descriptor_set_layouts = [_]vk.VkDescriptorSetLayout{descriptor_set_layout};

        const pipeline_layout_create_info = vk.VkPipelineLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = &descriptor_set_layouts,
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = &push_constant_ranges,
        };

        var pipeline_layout: vk.VkPipelineLayout = undefined;
        result = vk.Vulkan.createPipelineLayout(compute.device, &pipeline_layout_create_info, null, &pipeline_layout);
        if (result != vk.VK_SUCCESS) {
            return VulkanError.PipelineCreationFailed;
        }
        errdefer vk.Vulkan.destroyPipelineLayout(compute.device, pipeline_layout, null);

        // Create compute pipeline
        const stage_create_info = vk.VkPipelineShaderStageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = vk.VK_SHADER_STAGE_COMPUTE_BIT,
            .module = shader_module,
            .pName = "main",
            .pSpecializationInfo = null,
        };

        const pipeline_create_info = vk.VkComputePipelineCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = stage_create_info,
            .layout = pipeline_layout,
            .basePipelineHandle = @ptrCast(vk.VK_NULL_HANDLE),
            .basePipelineIndex = -1,
        };

        var pipeline: vk.VkPipeline = undefined;
        result = vk.Vulkan.createComputePipelines(
            compute.device,
            @ptrCast(vk.VK_NULL_HANDLE),
            1,
            @ptrCast(&pipeline_create_info),
            null,
            @ptrCast(&pipeline),
        );
        if (result != vk.VK_SUCCESS) {
            return VulkanError.PipelineCreationFailed;
        }
        errdefer vk.Vulkan.destroyPipeline(compute.device, pipeline, null);

        // Create descriptor pool
        const pool_sizes = [_]vk.VkDescriptorPoolSize{
            .{
                .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .descriptorCount = descriptor_count * 10, // Allocate space for multiple sets
            },
        };

        const pool_create_info = vk.VkDescriptorPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .maxSets = 10,
            .poolSizeCount = 1,
            .pPoolSizes = &pool_sizes,
        };

        var descriptor_pool: vk.VkDescriptorPool = undefined;
        result = vk.Vulkan.createDescriptorPool(compute.device, &pool_create_info, null, &descriptor_pool);
        if (result != vk.VK_SUCCESS) {
            return VulkanError.DescriptorPoolCreationFailed;
        }

        return Self{
            .compute = compute,
            .shader_module = shader_module,
            .descriptor_set_layout = descriptor_set_layout,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipeline,
            .descriptor_pool = descriptor_pool,
        };
    }

    pub fn destroy(self: *Self) void {
        vk.Vulkan.destroyDescriptorPool(self.compute.device, self.descriptor_pool, null);
        vk.Vulkan.destroyPipeline(self.compute.device, self.pipeline, null);
        vk.Vulkan.destroyPipelineLayout(self.compute.device, self.pipeline_layout, null);
        vk.Vulkan.destroyDescriptorSetLayout(self.compute.device, self.descriptor_set_layout, null);
        vk.Vulkan.destroyShaderModule(self.compute.device, self.shader_module, null);
    }

    pub fn execute(
        self: *Self,
        buffers: []VulkanBuffer,
        workgroup_count: [3]u32,
    ) !void {
        // Allocate descriptor set
        const set_layouts = [_]vk.VkDescriptorSetLayout{self.descriptor_set_layout};
        const alloc_info = vk.VkDescriptorSetAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = self.descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &set_layouts,
        };

        var descriptor_set: vk.VkDescriptorSet = undefined;
        var result = vk.Vulkan.allocateDescriptorSets(self.compute.device, &alloc_info, @ptrCast(&descriptor_set));
        if (result != vk.VK_SUCCESS) {
            return VulkanError.DescriptorSetAllocationFailed;
        }

        // Update descriptor sets
        var buffer_infos = try self.compute.allocator.alloc(vk.VkDescriptorBufferInfo, buffers.len);
        defer self.compute.allocator.free(buffer_infos);

        var writes = try self.compute.allocator.alloc(vk.VkWriteDescriptorSet, buffers.len);
        defer self.compute.allocator.free(writes);

        for (buffers, 0..) |buf, i| {
            buffer_infos[i] = vk.VkDescriptorBufferInfo{
                .buffer = buf.buffer,
                .offset = 0,
                .range = buf.size,
            };

            writes[i] = vk.VkWriteDescriptorSet{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = descriptor_set,
                .dstBinding = @intCast(i),
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pImageInfo = null,
                .pBufferInfo = buffer_infos[i .. i + 1].ptr,
                .pTexelBufferView = null,
            };
        }

        vk.Vulkan.updateDescriptorSets(self.compute.device, @intCast(writes.len), writes.ptr, 0, null);

        // Allocate command buffer
        const cmd_alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.compute.command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };

        var cmd_buffer: vk.VkCommandBuffer = undefined;
        result = vk.Vulkan.allocateCommandBuffers(self.compute.device, &cmd_alloc_info, @ptrCast(&cmd_buffer));
        if (result != vk.VK_SUCCESS) {
            return VulkanError.CommandBufferAllocationFailed;
        }

        // Record command buffer
        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };

        result = vk.Vulkan.beginCommandBuffer(cmd_buffer, &begin_info);
        if (result != vk.VK_SUCCESS) {
            return VulkanError.CommandBufferBeginFailed;
        }

        vk.Vulkan.cmdBindPipeline(cmd_buffer, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
        vk.Vulkan.cmdBindDescriptorSets(
            cmd_buffer,
            vk.VK_PIPELINE_BIND_POINT_COMPUTE,
            self.pipeline_layout,
            0,
            1,
            @ptrCast(&descriptor_set),
            0,
            null,
        );
        vk.Vulkan.cmdDispatch(cmd_buffer, workgroup_count[0], workgroup_count[1], workgroup_count[2]);

        result = vk.Vulkan.endCommandBuffer(cmd_buffer);
        if (result != vk.VK_SUCCESS) {
            return VulkanError.CommandBufferEndFailed;
        }

        // Submit and wait
        const submit_info = vk.VkSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = null,
            .commandBufferCount = 1,
            .pCommandBuffers = @ptrCast(&cmd_buffer),
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
        };

        result = vk.Vulkan.queueSubmit(self.compute.queue, 1, @ptrCast(&submit_info), @ptrCast(vk.VK_NULL_HANDLE));
        if (result != vk.VK_SUCCESS) {
            return VulkanError.QueueSubmitFailed;
        }

        result = vk.Vulkan.queueWaitIdle(self.compute.queue);
        if (result != vk.VK_SUCCESS) {
            return error.QueueWaitFailed;
        }
    }

    pub fn executeWithPushConstants(
        self: *Self,
        buffers: []VulkanBuffer,
        workgroup_count: [3]u32,
        push_constants: []const u32,
    ) !void {
        // Allocate descriptor set
        const set_layouts = [_]vk.VkDescriptorSetLayout{self.descriptor_set_layout};
        const alloc_info = vk.VkDescriptorSetAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = self.descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &set_layouts,
        };

        var descriptor_set: vk.VkDescriptorSet = undefined;
        var result = vk.Vulkan.allocateDescriptorSets(self.compute.device, &alloc_info, @ptrCast(&descriptor_set));
        if (result != vk.VK_SUCCESS) {
            return VulkanError.DescriptorSetAllocationFailed;
        }

        // Update descriptor sets
        var buffer_infos = try self.compute.allocator.alloc(vk.VkDescriptorBufferInfo, buffers.len);
        defer self.compute.allocator.free(buffer_infos);

        var writes = try self.compute.allocator.alloc(vk.VkWriteDescriptorSet, buffers.len);
        defer self.compute.allocator.free(writes);

        for (buffers, 0..) |buf, i| {
            buffer_infos[i] = vk.VkDescriptorBufferInfo{
                .buffer = buf.buffer,
                .offset = 0,
                .range = buf.size,
            };

            writes[i] = vk.VkWriteDescriptorSet{
                .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = descriptor_set,
                .dstBinding = @intCast(i),
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pImageInfo = null,
                .pBufferInfo = buffer_infos[i .. i + 1].ptr,
                .pTexelBufferView = null,
            };
        }

        vk.Vulkan.updateDescriptorSets(self.compute.device, @intCast(writes.len), writes.ptr, 0, null);

        // Allocate command buffer
        const cmd_alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.compute.command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };

        var cmd_buffer: vk.VkCommandBuffer = undefined;
        result = vk.Vulkan.allocateCommandBuffers(self.compute.device, &cmd_alloc_info, @ptrCast(&cmd_buffer));
        if (result != vk.VK_SUCCESS) {
            return VulkanError.CommandBufferAllocationFailed;
        }

        // Record command buffer
        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };

        result = vk.Vulkan.beginCommandBuffer(cmd_buffer, &begin_info);
        if (result != vk.VK_SUCCESS) {
            return VulkanError.CommandBufferBeginFailed;
        }

        vk.Vulkan.cmdBindPipeline(cmd_buffer, vk.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline);

        // Push constants
        if (push_constants.len > 0) {
            const push_size = push_constants.len * @sizeOf(u32);
            vk.Vulkan.cmdPushConstants(
                cmd_buffer,
                self.pipeline_layout,
                vk.VK_SHADER_STAGE_COMPUTE_BIT,
                0,
                @intCast(push_size),
                push_constants.ptr,
            );
        }

        vk.Vulkan.cmdBindDescriptorSets(
            cmd_buffer,
            vk.VK_PIPELINE_BIND_POINT_COMPUTE,
            self.pipeline_layout,
            0,
            1,
            @ptrCast(&descriptor_set),
            0,
            null,
        );
        vk.Vulkan.cmdDispatch(cmd_buffer, workgroup_count[0], workgroup_count[1], workgroup_count[2]);

        result = vk.Vulkan.endCommandBuffer(cmd_buffer);
        if (result != vk.VK_SUCCESS) {
            return VulkanError.CommandBufferEndFailed;
        }

        // Submit and wait
        const submit_info = vk.VkSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = null,
            .commandBufferCount = 1,
            .pCommandBuffers = @ptrCast(&cmd_buffer),
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
        };

        result = vk.Vulkan.queueSubmit(self.compute.queue, 1, @ptrCast(&submit_info), @ptrCast(vk.VK_NULL_HANDLE));
        if (result != vk.VK_SUCCESS) {
            return VulkanError.QueueSubmitFailed;
        }

        result = vk.Vulkan.queueWaitIdle(self.compute.queue);
        if (result != vk.VK_SUCCESS) {
            return error.QueueWaitFailed;
        }
    }
};

fn findMemoryType(
    compute: *VulkanCompute,
    type_filter: u32,
    properties: vk.VkMemoryPropertyFlags,
) !u32 {
    for (0..compute.memory_properties.memoryTypeCount) |i| {
        const type_bit = @as(u32, 1) << @intCast(i);
        if ((type_filter & type_bit) != 0) {
            const mem_type = compute.memory_properties.memoryTypes[i];
            if ((mem_type.propertyFlags & properties) == properties) {
                return @intCast(i);
            }
        }
    }
    return error.NoSuitableMemoryType;
}
