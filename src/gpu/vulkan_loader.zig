const std = @import("std");

pub const c = @cImport({
    @cInclude("vulkan/vulkan.h");
});

pub const VK_SUCCESS = c.VK_SUCCESS;
pub const VK_ERROR_OUT_OF_HOST_MEMORY = c.VK_ERROR_OUT_OF_HOST_MEMORY;
pub const VK_ERROR_OUT_OF_DEVICE_MEMORY = c.VK_ERROR_OUT_OF_DEVICE_MEMORY;
pub const VK_ERROR_INITIALIZATION_FAILED = c.VK_ERROR_INITIALIZATION_FAILED;
pub const VK_ERROR_DEVICE_LOST = c.VK_ERROR_DEVICE_LOST;
pub const VK_ERROR_MEMORY_MAP_FAILED = c.VK_ERROR_MEMORY_MAP_FAILED;

pub const VkInstance = c.VkInstance;
pub const VkPhysicalDevice = c.VkPhysicalDevice;
pub const VkDevice = c.VkDevice;
pub const VkQueue = c.VkQueue;
pub const VkCommandPool = c.VkCommandPool;
pub const VkCommandBuffer = c.VkCommandBuffer;
pub const VkBuffer = c.VkBuffer;
pub const VkDeviceMemory = c.VkDeviceMemory;
pub const VkShaderModule = c.VkShaderModule;
pub const VkPipeline = c.VkPipeline;
pub const VkPipelineLayout = c.VkPipelineLayout;
pub const VkDescriptorSetLayout = c.VkDescriptorSetLayout;
pub const VkDescriptorPool = c.VkDescriptorPool;
pub const VkDescriptorSet = c.VkDescriptorSet;
pub const VkFence = c.VkFence;
pub const VkResult = c.VkResult;

pub const VkPhysicalDeviceProperties = c.VkPhysicalDeviceProperties;
pub const VkPhysicalDeviceMemoryProperties = c.VkPhysicalDeviceMemoryProperties;
pub const VkQueueFamilyProperties = c.VkQueueFamilyProperties;
pub const VkMemoryRequirements = c.VkMemoryRequirements;

pub const VkInstanceCreateInfo = c.VkInstanceCreateInfo;
pub const VkDeviceCreateInfo = c.VkDeviceCreateInfo;
pub const VkDeviceQueueCreateInfo = c.VkDeviceQueueCreateInfo;
pub const VkBufferCreateInfo = c.VkBufferCreateInfo;
pub const VkMemoryAllocateInfo = c.VkMemoryAllocateInfo;
pub const VkShaderModuleCreateInfo = c.VkShaderModuleCreateInfo;
pub const VkPipelineLayoutCreateInfo = c.VkPipelineLayoutCreateInfo;
pub const VkComputePipelineCreateInfo = c.VkComputePipelineCreateInfo;
pub const VkDescriptorSetLayoutCreateInfo = c.VkDescriptorSetLayoutCreateInfo;
pub const VkDescriptorPoolCreateInfo = c.VkDescriptorPoolCreateInfo;
pub const VkDescriptorSetAllocateInfo = c.VkDescriptorSetAllocateInfo;
pub const VkCommandPoolCreateInfo = c.VkCommandPoolCreateInfo;
pub const VkCommandBufferAllocateInfo = c.VkCommandBufferAllocateInfo;
pub const VkCommandBufferBeginInfo = c.VkCommandBufferBeginInfo;
pub const VkSubmitInfo = c.VkSubmitInfo;
pub const VkFenceCreateInfo = c.VkFenceCreateInfo;
pub const VkWriteDescriptorSet = c.VkWriteDescriptorSet;
pub const VkDescriptorBufferInfo = c.VkDescriptorBufferInfo;
pub const VkPipelineShaderStageCreateInfo = c.VkPipelineShaderStageCreateInfo;

pub const VkBufferUsageFlags = c.VkBufferUsageFlags;
pub const VkMemoryPropertyFlags = c.VkMemoryPropertyFlags;
pub const VkQueueFlags = c.VkQueueFlags;

pub const VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
pub const VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
pub const VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
pub const VK_STRUCTURE_TYPE_SUBMIT_INFO = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
pub const VK_STRUCTURE_TYPE_FENCE_CREATE_INFO = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
pub const VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;

pub const VK_BUFFER_USAGE_STORAGE_BUFFER_BIT = c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
pub const VK_BUFFER_USAGE_TRANSFER_SRC_BIT = c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
pub const VK_BUFFER_USAGE_TRANSFER_DST_BIT = c.VK_BUFFER_USAGE_TRANSFER_DST_BIT;

pub const VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT = c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT;
pub const VK_MEMORY_PROPERTY_HOST_COHERENT_BIT = c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
pub const VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT = c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;

pub const VK_QUEUE_COMPUTE_BIT = c.VK_QUEUE_COMPUTE_BIT;

pub const VK_DESCRIPTOR_TYPE_STORAGE_BUFFER = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;

pub const VK_SHADER_STAGE_COMPUTE_BIT = c.VK_SHADER_STAGE_COMPUTE_BIT;

pub const VK_PIPELINE_BIND_POINT_COMPUTE = c.VK_PIPELINE_BIND_POINT_COMPUTE;

pub const VK_COMMAND_BUFFER_LEVEL_PRIMARY = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;

pub const VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;

pub const VkApplicationInfo = c.VkApplicationInfo;
pub const VK_STRUCTURE_TYPE_APPLICATION_INFO = c.VK_STRUCTURE_TYPE_APPLICATION_INFO;
pub const VK_API_VERSION_1_0 = c.VK_API_VERSION_1_0;

pub const VK_NULL_HANDLE = @as(?*anyopaque, null);

pub const Vulkan = struct {
    pub fn createInstance(create_info: *const VkInstanceCreateInfo, allocator: ?*const c.VkAllocationCallbacks, instance: *VkInstance) VkResult {
        return c.vkCreateInstance(create_info, allocator, instance);
    }

    pub fn destroyInstance(instance: VkInstance, allocator: ?*const c.VkAllocationCallbacks) void {
        c.vkDestroyInstance(instance, allocator);
    }

    pub fn enumeratePhysicalDevices(instance: VkInstance, count: *u32, devices: ?[*]VkPhysicalDevice) VkResult {
        return c.vkEnumeratePhysicalDevices(instance, count, devices);
    }

    pub fn getPhysicalDeviceProperties(device: VkPhysicalDevice, props: *VkPhysicalDeviceProperties) void {
        c.vkGetPhysicalDeviceProperties(device, props);
    }

    pub fn getPhysicalDeviceMemoryProperties(device: VkPhysicalDevice, props: *VkPhysicalDeviceMemoryProperties) void {
        c.vkGetPhysicalDeviceMemoryProperties(device, props);
    }

    pub fn getPhysicalDeviceQueueFamilyProperties(device: VkPhysicalDevice, count: *u32, props: ?[*]VkQueueFamilyProperties) void {
        c.vkGetPhysicalDeviceQueueFamilyProperties(device, count, props);
    }

    pub fn createDevice(physical_device: VkPhysicalDevice, create_info: *const VkDeviceCreateInfo, allocator: ?*const c.VkAllocationCallbacks, device: *VkDevice) VkResult {
        return c.vkCreateDevice(physical_device, create_info, allocator, device);
    }

    pub fn destroyDevice(device: VkDevice, allocator: ?*const c.VkAllocationCallbacks) void {
        c.vkDestroyDevice(device, allocator);
    }

    pub fn getDeviceQueue(device: VkDevice, queue_family: u32, queue_index: u32, queue: *VkQueue) void {
        c.vkGetDeviceQueue(device, queue_family, queue_index, queue);
    }

    pub fn createBuffer(device: VkDevice, create_info: *const VkBufferCreateInfo, allocator: ?*const c.VkAllocationCallbacks, buffer: *VkBuffer) VkResult {
        return c.vkCreateBuffer(device, create_info, allocator, buffer);
    }

    pub fn destroyBuffer(device: VkDevice, buffer: VkBuffer, allocator: ?*const c.VkAllocationCallbacks) void {
        c.vkDestroyBuffer(device, buffer, allocator);
    }

    pub fn getBufferMemoryRequirements(device: VkDevice, buffer: VkBuffer, requirements: *VkMemoryRequirements) void {
        c.vkGetBufferMemoryRequirements(device, buffer, requirements);
    }

    pub fn allocateMemory(device: VkDevice, alloc_info: *const VkMemoryAllocateInfo, allocator: ?*const c.VkAllocationCallbacks, memory: *VkDeviceMemory) VkResult {
        return c.vkAllocateMemory(device, alloc_info, allocator, memory);
    }

    pub fn freeMemory(device: VkDevice, memory: VkDeviceMemory, allocator: ?*const c.VkAllocationCallbacks) void {
        c.vkFreeMemory(device, memory, allocator);
    }

    pub fn bindBufferMemory(device: VkDevice, buffer: VkBuffer, memory: VkDeviceMemory, offset: u64) VkResult {
        return c.vkBindBufferMemory(device, buffer, memory, offset);
    }

    pub fn mapMemory(device: VkDevice, memory: VkDeviceMemory, offset: u64, size: u64, flags: u32, data: *?*anyopaque) VkResult {
        return c.vkMapMemory(device, memory, offset, size, flags, data);
    }

    pub fn unmapMemory(device: VkDevice, memory: VkDeviceMemory) void {
        c.vkUnmapMemory(device, memory);
    }

    pub fn createShaderModule(device: VkDevice, create_info: *const VkShaderModuleCreateInfo, allocator: ?*const c.VkAllocationCallbacks, shader: *VkShaderModule) VkResult {
        return c.vkCreateShaderModule(device, create_info, allocator, shader);
    }

    pub fn destroyShaderModule(device: VkDevice, shader: VkShaderModule, allocator: ?*const c.VkAllocationCallbacks) void {
        c.vkDestroyShaderModule(device, shader, allocator);
    }

    pub fn createDescriptorSetLayout(device: VkDevice, create_info: *const VkDescriptorSetLayoutCreateInfo, allocator: ?*const c.VkAllocationCallbacks, layout: *VkDescriptorSetLayout) VkResult {
        return c.vkCreateDescriptorSetLayout(device, create_info, allocator, layout);
    }

    pub fn destroyDescriptorSetLayout(device: VkDevice, layout: VkDescriptorSetLayout, allocator: ?*const c.VkAllocationCallbacks) void {
        c.vkDestroyDescriptorSetLayout(device, layout, allocator);
    }

    pub fn createPipelineLayout(device: VkDevice, create_info: *const VkPipelineLayoutCreateInfo, allocator: ?*const c.VkAllocationCallbacks, layout: *VkPipelineLayout) VkResult {
        return c.vkCreatePipelineLayout(device, create_info, allocator, layout);
    }

    pub fn destroyPipelineLayout(device: VkDevice, layout: VkPipelineLayout, allocator: ?*const c.VkAllocationCallbacks) void {
        c.vkDestroyPipelineLayout(device, layout, allocator);
    }

    pub fn createComputePipelines(device: VkDevice, cache: c.VkPipelineCache, count: u32, create_infos: [*]const VkComputePipelineCreateInfo, allocator: ?*const c.VkAllocationCallbacks, pipelines: [*]VkPipeline) VkResult {
        return c.vkCreateComputePipelines(device, cache, count, create_infos, allocator, pipelines);
    }

    pub fn destroyPipeline(device: VkDevice, pipeline: VkPipeline, allocator: ?*const c.VkAllocationCallbacks) void {
        c.vkDestroyPipeline(device, pipeline, allocator);
    }

    pub fn createDescriptorPool(device: VkDevice, create_info: *const VkDescriptorPoolCreateInfo, allocator: ?*const c.VkAllocationCallbacks, pool: *VkDescriptorPool) VkResult {
        return c.vkCreateDescriptorPool(device, create_info, allocator, pool);
    }

    pub fn destroyDescriptorPool(device: VkDevice, pool: VkDescriptorPool, allocator: ?*const c.VkAllocationCallbacks) void {
        c.vkDestroyDescriptorPool(device, pool, allocator);
    }

    pub fn allocateDescriptorSets(device: VkDevice, alloc_info: *const VkDescriptorSetAllocateInfo, sets: [*]VkDescriptorSet) VkResult {
        return c.vkAllocateDescriptorSets(device, alloc_info, sets);
    }

    pub fn updateDescriptorSets(device: VkDevice, write_count: u32, writes: [*]const VkWriteDescriptorSet, copy_count: u32, copies: ?[*]const c.VkCopyDescriptorSet) void {
        c.vkUpdateDescriptorSets(device, write_count, writes, copy_count, copies);
    }

    pub fn createCommandPool(device: VkDevice, create_info: *const VkCommandPoolCreateInfo, allocator: ?*const c.VkAllocationCallbacks, pool: *VkCommandPool) VkResult {
        return c.vkCreateCommandPool(device, create_info, allocator, pool);
    }

    pub fn destroyCommandPool(device: VkDevice, pool: VkCommandPool, allocator: ?*const c.VkAllocationCallbacks) void {
        c.vkDestroyCommandPool(device, pool, allocator);
    }

    pub fn allocateCommandBuffers(device: VkDevice, alloc_info: *const VkCommandBufferAllocateInfo, buffers: [*]VkCommandBuffer) VkResult {
        return c.vkAllocateCommandBuffers(device, alloc_info, buffers);
    }

    pub fn beginCommandBuffer(buffer: VkCommandBuffer, begin_info: *const VkCommandBufferBeginInfo) VkResult {
        return c.vkBeginCommandBuffer(buffer, begin_info);
    }

    pub fn endCommandBuffer(buffer: VkCommandBuffer) VkResult {
        return c.vkEndCommandBuffer(buffer);
    }

    pub fn cmdBindPipeline(buffer: VkCommandBuffer, bind_point: c.VkPipelineBindPoint, pipeline: VkPipeline) void {
        c.vkCmdBindPipeline(buffer, bind_point, pipeline);
    }

    pub fn cmdBindDescriptorSets(buffer: VkCommandBuffer, bind_point: c.VkPipelineBindPoint, layout: VkPipelineLayout, first_set: u32, set_count: u32, sets: [*]const VkDescriptorSet, dynamic_offset_count: u32, dynamic_offsets: ?[*]const u32) void {
        c.vkCmdBindDescriptorSets(buffer, bind_point, layout, first_set, set_count, sets, dynamic_offset_count, dynamic_offsets);
    }

    pub fn cmdDispatch(buffer: VkCommandBuffer, x: u32, y: u32, z: u32) void {
        c.vkCmdDispatch(buffer, x, y, z);
    }

    pub fn queueSubmit(queue: VkQueue, submit_count: u32, submits: [*]const VkSubmitInfo, fence: VkFence) VkResult {
        return c.vkQueueSubmit(queue, submit_count, submits, fence);
    }

    pub fn queueWaitIdle(queue: VkQueue) VkResult {
        return c.vkQueueWaitIdle(queue);
    }

    pub fn createFence(device: VkDevice, create_info: *const VkFenceCreateInfo, allocator: ?*const c.VkAllocationCallbacks, fence: *VkFence) VkResult {
        return c.vkCreateFence(device, create_info, allocator, fence);
    }

    pub fn destroyFence(device: VkDevice, fence: VkFence, allocator: ?*const c.VkAllocationCallbacks) void {
        c.vkDestroyFence(device, fence, allocator);
    }

    pub fn waitForFences(device: VkDevice, fence_count: u32, fences: [*]const VkFence, wait_all: u32, timeout: u64) VkResult {
        return c.vkWaitForFences(device, fence_count, fences, wait_all, timeout);
    }

    pub fn resetFences(device: VkDevice, fence_count: u32, fences: [*]const VkFence) VkResult {
        return c.vkResetFences(device, fence_count, fences);
    }
};
