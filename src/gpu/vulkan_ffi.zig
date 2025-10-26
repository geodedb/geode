// Manual FFI bindings for Vulkan
// Replaces @cImport to avoid Zig 0.15.1 module system issues
// CANARY: REQ=REQ-GPU-VK-001; FEATURE="Vulkan FFI"; ASPECT=Foundation; STATUS=IMPLEMENTED; OWNER=gpu; UPDATED=2025-10-26

const std = @import("std");

// Result codes
pub const VK_SUCCESS: i32 = 0;
pub const VK_ERROR_OUT_OF_HOST_MEMORY: i32 = -1;
pub const VK_ERROR_OUT_OF_DEVICE_MEMORY: i32 = -2;
pub const VK_ERROR_INITIALIZATION_FAILED: i32 = -3;
pub const VK_ERROR_DEVICE_LOST: i32 = -4;
pub const VK_ERROR_MEMORY_MAP_FAILED: i32 = -5;
pub const VK_ERROR_LAYER_NOT_PRESENT: i32 = -6;
pub const VK_ERROR_EXTENSION_NOT_PRESENT: i32 = -7;
pub const VK_ERROR_FEATURE_NOT_PRESENT: i32 = -8;

pub const VkResult = i32;

// Handle types (opaque pointers)
pub const VkInstance = ?*anyopaque;
pub const VkPhysicalDevice = ?*anyopaque;
pub const VkDevice = ?*anyopaque;
pub const VkQueue = ?*anyopaque;
pub const VkCommandPool = ?*anyopaque;
pub const VkCommandBuffer = ?*anyopaque;
pub const VkBuffer = ?*anyopaque;
pub const VkDeviceMemory = ?*anyopaque;
pub const VkShaderModule = ?*anyopaque;
pub const VkPipeline = ?*anyopaque;
pub const VkPipelineLayout = ?*anyopaque;
pub const VkDescriptorSetLayout = ?*anyopaque;
pub const VkDescriptorPool = ?*anyopaque;
pub const VkDescriptorSet = ?*anyopaque;
pub const VkFence = ?*anyopaque;
pub const VkPipelineCache = ?*anyopaque;

pub const VK_NULL_HANDLE: ?*anyopaque = null;

// Structure types
pub const VK_STRUCTURE_TYPE_APPLICATION_INFO: u32 = 0;
pub const VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO: u32 = 1;
pub const VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO: u32 = 2;
pub const VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO: u32 = 3;
pub const VK_STRUCTURE_TYPE_SUBMIT_INFO: u32 = 4;
pub const VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO: u32 = 5;
pub const VK_STRUCTURE_TYPE_FENCE_CREATE_INFO: u32 = 8;
pub const VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO: u32 = 39;
pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO: u32 = 40;
pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO: u32 = 42;
pub const VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO: u32 = 12;
pub const VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO: u32 = 16;
pub const VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO: u32 = 30;
pub const VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO: u32 = 29;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO: u32 = 32;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO: u32 = 33;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO: u32 = 34;
pub const VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET: u32 = 35;
pub const VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO: u32 = 18;
pub const VK_STRUCTURE_TYPE_PUSH_CONSTANT_RANGE: u32 = 31;

// Flags
pub const VK_BUFFER_USAGE_STORAGE_BUFFER_BIT: u32 = 0x00000080;
pub const VK_BUFFER_USAGE_TRANSFER_SRC_BIT: u32 = 0x00000001;
pub const VK_BUFFER_USAGE_TRANSFER_DST_BIT: u32 = 0x00000002;

pub const VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT: u32 = 0x00000001;
pub const VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT: u32 = 0x00000002;
pub const VK_MEMORY_PROPERTY_HOST_COHERENT_BIT: u32 = 0x00000004;

pub const VK_QUEUE_COMPUTE_BIT: u32 = 0x00000002;

pub const VK_DESCRIPTOR_TYPE_STORAGE_BUFFER: u32 = 7;

pub const VK_SHADER_STAGE_COMPUTE_BIT: u32 = 0x00000020;

pub const VK_PIPELINE_BIND_POINT_COMPUTE: u32 = 1;

pub const VK_COMMAND_BUFFER_LEVEL_PRIMARY: u32 = 0;

pub const VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT: u32 = 0x00000001;

pub const VK_API_VERSION_1_0: u32 = (1 << 22);

pub const VK_MAX_PHYSICAL_DEVICE_NAME_SIZE: usize = 256;
pub const VK_UUID_SIZE: usize = 16;

pub const VK_SHARING_MODE_EXCLUSIVE: u32 = 0;
pub const VK_SHARING_MODE_CONCURRENT: u32 = 1;

pub const VkBufferUsageFlags = u32;
pub const VkMemoryPropertyFlags = u32;
pub const VkQueueFlags = u32;
pub const VkShaderStageFlags = u32;

// Structures
pub const VkApplicationInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    pApplicationName: ?[*:0]const u8,
    applicationVersion: u32,
    pEngineName: ?[*:0]const u8,
    engineVersion: u32,
    apiVersion: u32,
};

pub const VkInstanceCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    pApplicationInfo: ?*const VkApplicationInfo,
    enabledLayerCount: u32,
    ppEnabledLayerNames: ?[*]const [*:0]const u8,
    enabledExtensionCount: u32,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8,
};

pub const VkPhysicalDeviceProperties = extern struct {
    apiVersion: u32,
    driverVersion: u32,
    vendorID: u32,
    deviceID: u32,
    deviceType: u32,
    deviceName: [VK_MAX_PHYSICAL_DEVICE_NAME_SIZE]u8,
    pipelineCacheUUID: [VK_UUID_SIZE]u8,
    limits: VkPhysicalDeviceLimits,
    sparseProperties: VkPhysicalDeviceSparseProperties,
};

pub const VkPhysicalDeviceLimits = extern struct {
    maxImageDimension1D: u32,
    maxImageDimension2D: u32,
    maxImageDimension3D: u32,
    maxImageDimensionCube: u32,
    maxImageArrayLayers: u32,
    maxTexelBufferElements: u32,
    maxUniformBufferRange: u32,
    maxStorageBufferRange: u32,
    maxPushConstantsSize: u32,
    maxMemoryAllocationCount: u32,
    maxSamplerAllocationCount: u32,
    bufferImageGranularity: u64,
    sparseAddressSpaceSize: u64,
    maxBoundDescriptorSets: u32,
    maxPerStageDescriptorSamplers: u32,
    maxPerStageDescriptorUniformBuffers: u32,
    maxPerStageDescriptorStorageBuffers: u32,
    maxPerStageDescriptorSampledImages: u32,
    maxPerStageDescriptorStorageImages: u32,
    maxPerStageDescriptorInputAttachments: u32,
    maxPerStageResources: u32,
    maxDescriptorSetSamplers: u32,
    maxDescriptorSetUniformBuffers: u32,
    maxDescriptorSetUniformBuffersDynamic: u32,
    maxDescriptorSetStorageBuffers: u32,
    maxDescriptorSetStorageBuffersDynamic: u32,
    maxDescriptorSetSampledImages: u32,
    maxDescriptorSetStorageImages: u32,
    maxDescriptorSetInputAttachments: u32,
    maxVertexInputAttributes: u32,
    maxVertexInputBindings: u32,
    maxVertexInputAttributeOffset: u32,
    maxVertexInputBindingStride: u32,
    maxVertexOutputComponents: u32,
    maxTessellationGenerationLevel: u32,
    maxTessellationPatchSize: u32,
    maxTessellationControlPerVertexInputComponents: u32,
    maxTessellationControlPerVertexOutputComponents: u32,
    maxTessellationControlPerPatchOutputComponents: u32,
    maxTessellationControlTotalOutputComponents: u32,
    maxTessellationEvaluationInputComponents: u32,
    maxTessellationEvaluationOutputComponents: u32,
    maxGeometryShaderInvocations: u32,
    maxGeometryInputComponents: u32,
    maxGeometryOutputComponents: u32,
    maxGeometryOutputVertices: u32,
    maxGeometryTotalOutputComponents: u32,
    maxFragmentInputComponents: u32,
    maxFragmentOutputAttachments: u32,
    maxFragmentDualSrcAttachments: u32,
    maxFragmentCombinedOutputResources: u32,
    maxComputeSharedMemorySize: u32,
    maxComputeWorkGroupCount: [3]u32,
    maxComputeWorkGroupInvocations: u32,
    maxComputeWorkGroupSize: [3]u32,
    subPixelPrecisionBits: u32,
    subTexelPrecisionBits: u32,
    mipmapPrecisionBits: u32,
    maxDrawIndexedIndexValue: u32,
    maxDrawIndirectCount: u32,
    maxSamplerLodBias: f32,
    maxSamplerAnisotropy: f32,
    maxViewports: u32,
    maxViewportDimensions: [2]u32,
    viewportBoundsRange: [2]f32,
    viewportSubPixelBits: u32,
    minMemoryMapAlignment: usize,
    minTexelBufferOffsetAlignment: u64,
    minUniformBufferOffsetAlignment: u64,
    minStorageBufferOffsetAlignment: u64,
    minTexelOffset: i32,
    maxTexelOffset: u32,
    minTexelGatherOffset: i32,
    maxTexelGatherOffset: u32,
    minInterpolationOffset: f32,
    maxInterpolationOffset: f32,
    subPixelInterpolationOffsetBits: u32,
    maxFramebufferWidth: u32,
    maxFramebufferHeight: u32,
    maxFramebufferLayers: u32,
    framebufferColorSampleCounts: u32,
    framebufferDepthSampleCounts: u32,
    framebufferStencilSampleCounts: u32,
    framebufferNoAttachmentsSampleCounts: u32,
    maxColorAttachments: u32,
    sampledImageColorSampleCounts: u32,
    sampledImageIntegerSampleCounts: u32,
    sampledImageDepthSampleCounts: u32,
    sampledImageStencilSampleCounts: u32,
    storageImageSampleCounts: u32,
    maxSampleMaskWords: u32,
    timestampComputeAndGraphics: u32,
    timestampPeriod: f32,
    maxClipDistances: u32,
    maxCullDistances: u32,
    maxCombinedClipAndCullDistances: u32,
    discreteQueuePriorities: u32,
    pointSizeRange: [2]f32,
    lineWidthRange: [2]f32,
    pointSizeGranularity: f32,
    lineWidthGranularity: f32,
    strictLines: u32,
    standardSampleLocations: u32,
    optimalBufferCopyOffsetAlignment: u64,
    optimalBufferCopyRowPitchAlignment: u64,
    nonCoherentAtomSize: u64,
};

pub const VkPhysicalDeviceSparseProperties = extern struct {
    residencyStandard2DBlockShape: u32,
    residencyStandard2DMultisampleBlockShape: u32,
    residencyStandard3DBlockShape: u32,
    residencyAlignedMipSize: u32,
    residencyNonResidentStrict: u32,
};

pub const VkPhysicalDeviceMemoryProperties = extern struct {
    memoryTypeCount: u32,
    memoryTypes: [32]VkMemoryType,
    memoryHeapCount: u32,
    memoryHeaps: [16]VkMemoryHeap,
};

pub const VkMemoryType = extern struct {
    propertyFlags: VkMemoryPropertyFlags,
    heapIndex: u32,
};

pub const VkMemoryHeap = extern struct {
    size: u64,
    flags: u32,
};

pub const VkQueueFamilyProperties = extern struct {
    queueFlags: VkQueueFlags,
    queueCount: u32,
    timestampValidBits: u32,
    minImageTransferGranularity: VkExtent3D,
};

pub const VkExtent3D = extern struct {
    width: u32,
    height: u32,
    depth: u32,
};

pub const VkDeviceQueueCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    queueFamilyIndex: u32,
    queueCount: u32,
    pQueuePriorities: [*]const f32,
};

pub const VkDeviceCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    queueCreateInfoCount: u32,
    pQueueCreateInfos: [*]const VkDeviceQueueCreateInfo,
    enabledLayerCount: u32,
    ppEnabledLayerNames: ?[*]const [*:0]const u8,
    enabledExtensionCount: u32,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8,
    pEnabledFeatures: ?*const anyopaque,
};

pub const VkBufferCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    size: u64,
    usage: VkBufferUsageFlags,
    sharingMode: u32,
    queueFamilyIndexCount: u32,
    pQueueFamilyIndices: ?[*]const u32,
};

pub const VkMemoryRequirements = extern struct {
    size: u64,
    alignment: u64,
    memoryTypeBits: u32,
};

pub const VkMemoryAllocateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    allocationSize: u64,
    memoryTypeIndex: u32,
};

pub const VkShaderModuleCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    codeSize: usize,
    pCode: [*]const u32,
};

pub const VkDescriptorSetLayoutBinding = extern struct {
    binding: u32,
    descriptorType: u32,
    descriptorCount: u32,
    stageFlags: VkShaderStageFlags,
    pImmutableSamplers: ?*const anyopaque,
};

pub const VkDescriptorSetLayoutCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    bindingCount: u32,
    pBindings: [*]const VkDescriptorSetLayoutBinding,
};

pub const VkPushConstantRange = extern struct {
    stageFlags: VkShaderStageFlags,
    offset: u32,
    size: u32,
};

pub const VkPipelineLayoutCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    setLayoutCount: u32,
    pSetLayouts: ?[*]const VkDescriptorSetLayout,
    pushConstantRangeCount: u32,
    pPushConstantRanges: ?[*]const VkPushConstantRange,
};

pub const VkPipelineShaderStageCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    stage: VkShaderStageFlags,
    module: VkShaderModule,
    pName: [*:0]const u8,
    pSpecializationInfo: ?*const anyopaque,
};

pub const VkComputePipelineCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    stage: VkPipelineShaderStageCreateInfo,
    layout: VkPipelineLayout,
    basePipelineHandle: VkPipeline,
    basePipelineIndex: i32,
};

pub const VkDescriptorPoolSize = extern struct {
    type: u32,
    descriptorCount: u32,
};

pub const VkDescriptorPoolCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    maxSets: u32,
    poolSizeCount: u32,
    pPoolSizes: [*]const VkDescriptorPoolSize,
};

pub const VkDescriptorSetAllocateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    descriptorPool: VkDescriptorPool,
    descriptorSetCount: u32,
    pSetLayouts: [*]const VkDescriptorSetLayout,
};

pub const VkDescriptorBufferInfo = extern struct {
    buffer: VkBuffer,
    offset: u64,
    range: u64,
};

pub const VkWriteDescriptorSet = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    dstSet: VkDescriptorSet,
    dstBinding: u32,
    dstArrayElement: u32,
    descriptorCount: u32,
    descriptorType: u32,
    pImageInfo: ?*const anyopaque,
    pBufferInfo: ?[*]const VkDescriptorBufferInfo,
    pTexelBufferView: ?*const anyopaque,
};

pub const VkCommandPoolCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    queueFamilyIndex: u32,
};

pub const VkCommandBufferAllocateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    commandPool: VkCommandPool,
    level: u32,
    commandBufferCount: u32,
};

pub const VkCommandBufferBeginInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
    pInheritanceInfo: ?*const anyopaque,
};

pub const VkSubmitInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    waitSemaphoreCount: u32,
    pWaitSemaphores: ?*const anyopaque,
    pWaitDstStageMask: ?[*]const u32,
    commandBufferCount: u32,
    pCommandBuffers: [*]const VkCommandBuffer,
    signalSemaphoreCount: u32,
    pSignalSemaphores: ?*const anyopaque,
};

pub const VkFenceCreateInfo = extern struct {
    sType: u32,
    pNext: ?*const anyopaque,
    flags: u32,
};

// Extern function declarations
extern "vulkan" fn vkCreateInstance(pCreateInfo: *const VkInstanceCreateInfo, pAllocator: ?*const anyopaque, pInstance: *VkInstance) VkResult;
extern "vulkan" fn vkDestroyInstance(instance: VkInstance, pAllocator: ?*const anyopaque) void;
extern "vulkan" fn vkEnumeratePhysicalDevices(instance: VkInstance, pPhysicalDeviceCount: *u32, pPhysicalDevices: ?[*]VkPhysicalDevice) VkResult;
extern "vulkan" fn vkGetPhysicalDeviceProperties(physicalDevice: VkPhysicalDevice, pProperties: *VkPhysicalDeviceProperties) void;
extern "vulkan" fn vkGetPhysicalDeviceMemoryProperties(physicalDevice: VkPhysicalDevice, pMemoryProperties: *VkPhysicalDeviceMemoryProperties) void;
extern "vulkan" fn vkGetPhysicalDeviceQueueFamilyProperties(physicalDevice: VkPhysicalDevice, pQueueFamilyPropertyCount: *u32, pQueueFamilyProperties: ?[*]VkQueueFamilyProperties) void;
extern "vulkan" fn vkCreateDevice(physicalDevice: VkPhysicalDevice, pCreateInfo: *const VkDeviceCreateInfo, pAllocator: ?*const anyopaque, pDevice: *VkDevice) VkResult;
extern "vulkan" fn vkDestroyDevice(device: VkDevice, pAllocator: ?*const anyopaque) void;
extern "vulkan" fn vkGetDeviceQueue(device: VkDevice, queueFamilyIndex: u32, queueIndex: u32, pQueue: *VkQueue) void;
extern "vulkan" fn vkCreateBuffer(device: VkDevice, pCreateInfo: *const VkBufferCreateInfo, pAllocator: ?*const anyopaque, pBuffer: *VkBuffer) VkResult;
extern "vulkan" fn vkDestroyBuffer(device: VkDevice, buffer: VkBuffer, pAllocator: ?*const anyopaque) void;
extern "vulkan" fn vkGetBufferMemoryRequirements(device: VkDevice, buffer: VkBuffer, pMemoryRequirements: *VkMemoryRequirements) void;
extern "vulkan" fn vkAllocateMemory(device: VkDevice, pAllocateInfo: *const VkMemoryAllocateInfo, pAllocator: ?*const anyopaque, pMemory: *VkDeviceMemory) VkResult;
extern "vulkan" fn vkFreeMemory(device: VkDevice, memory: VkDeviceMemory, pAllocator: ?*const anyopaque) void;
extern "vulkan" fn vkBindBufferMemory(device: VkDevice, buffer: VkBuffer, memory: VkDeviceMemory, memoryOffset: u64) VkResult;
extern "vulkan" fn vkMapMemory(device: VkDevice, memory: VkDeviceMemory, offset: u64, size: u64, flags: u32, ppData: *?*anyopaque) VkResult;
extern "vulkan" fn vkUnmapMemory(device: VkDevice, memory: VkDeviceMemory) void;
extern "vulkan" fn vkCreateShaderModule(device: VkDevice, pCreateInfo: *const VkShaderModuleCreateInfo, pAllocator: ?*const anyopaque, pShaderModule: *VkShaderModule) VkResult;
extern "vulkan" fn vkDestroyShaderModule(device: VkDevice, shaderModule: VkShaderModule, pAllocator: ?*const anyopaque) void;
extern "vulkan" fn vkCreateDescriptorSetLayout(device: VkDevice, pCreateInfo: *const VkDescriptorSetLayoutCreateInfo, pAllocator: ?*const anyopaque, pSetLayout: *VkDescriptorSetLayout) VkResult;
extern "vulkan" fn vkDestroyDescriptorSetLayout(device: VkDevice, descriptorSetLayout: VkDescriptorSetLayout, pAllocator: ?*const anyopaque) void;
extern "vulkan" fn vkCreatePipelineLayout(device: VkDevice, pCreateInfo: *const VkPipelineLayoutCreateInfo, pAllocator: ?*const anyopaque, pPipelineLayout: *VkPipelineLayout) VkResult;
extern "vulkan" fn vkDestroyPipelineLayout(device: VkDevice, pipelineLayout: VkPipelineLayout, pAllocator: ?*const anyopaque) void;
extern "vulkan" fn vkCreateComputePipelines(device: VkDevice, pipelineCache: VkPipelineCache, createInfoCount: u32, pCreateInfos: [*]const VkComputePipelineCreateInfo, pAllocator: ?*const anyopaque, pPipelines: [*]VkPipeline) VkResult;
extern "vulkan" fn vkDestroyPipeline(device: VkDevice, pipeline: VkPipeline, pAllocator: ?*const anyopaque) void;
extern "vulkan" fn vkCreateDescriptorPool(device: VkDevice, pCreateInfo: *const VkDescriptorPoolCreateInfo, pAllocator: ?*const anyopaque, pDescriptorPool: *VkDescriptorPool) VkResult;
extern "vulkan" fn vkDestroyDescriptorPool(device: VkDevice, descriptorPool: VkDescriptorPool, pAllocator: ?*const anyopaque) void;
extern "vulkan" fn vkAllocateDescriptorSets(device: VkDevice, pAllocateInfo: *const VkDescriptorSetAllocateInfo, pDescriptorSets: [*]VkDescriptorSet) VkResult;
extern "vulkan" fn vkUpdateDescriptorSets(device: VkDevice, descriptorWriteCount: u32, pDescriptorWrites: [*]const VkWriteDescriptorSet, descriptorCopyCount: u32, pDescriptorCopies: ?*const anyopaque) void;
extern "vulkan" fn vkCreateCommandPool(device: VkDevice, pCreateInfo: *const VkCommandPoolCreateInfo, pAllocator: ?*const anyopaque, pCommandPool: *VkCommandPool) VkResult;
extern "vulkan" fn vkDestroyCommandPool(device: VkDevice, commandPool: VkCommandPool, pAllocator: ?*const anyopaque) void;
extern "vulkan" fn vkAllocateCommandBuffers(device: VkDevice, pAllocateInfo: *const VkCommandBufferAllocateInfo, pCommandBuffers: [*]VkCommandBuffer) VkResult;
extern "vulkan" fn vkBeginCommandBuffer(commandBuffer: VkCommandBuffer, pBeginInfo: *const VkCommandBufferBeginInfo) VkResult;
extern "vulkan" fn vkEndCommandBuffer(commandBuffer: VkCommandBuffer) VkResult;
extern "vulkan" fn vkCmdBindPipeline(commandBuffer: VkCommandBuffer, pipelineBindPoint: u32, pipeline: VkPipeline) void;
extern "vulkan" fn vkCmdBindDescriptorSets(commandBuffer: VkCommandBuffer, pipelineBindPoint: u32, layout: VkPipelineLayout, firstSet: u32, descriptorSetCount: u32, pDescriptorSets: [*]const VkDescriptorSet, dynamicOffsetCount: u32, pDynamicOffsets: ?[*]const u32) void;
extern "vulkan" fn vkCmdPushConstants(commandBuffer: VkCommandBuffer, layout: VkPipelineLayout, stageFlags: VkShaderStageFlags, offset: u32, size: u32, pValues: *const anyopaque) void;
extern "vulkan" fn vkCmdDispatch(commandBuffer: VkCommandBuffer, groupCountX: u32, groupCountY: u32, groupCountZ: u32) void;
extern "vulkan" fn vkQueueSubmit(queue: VkQueue, submitCount: u32, pSubmits: [*]const VkSubmitInfo, fence: VkFence) VkResult;
extern "vulkan" fn vkQueueWaitIdle(queue: VkQueue) VkResult;
extern "vulkan" fn vkCreateFence(device: VkDevice, pCreateInfo: *const VkFenceCreateInfo, pAllocator: ?*const anyopaque, pFence: *VkFence) VkResult;
extern "vulkan" fn vkDestroyFence(device: VkDevice, fence: VkFence, pAllocator: ?*const anyopaque) void;
extern "vulkan" fn vkWaitForFences(device: VkDevice, fenceCount: u32, pFences: [*]const VkFence, waitAll: u32, timeout: u64) VkResult;
extern "vulkan" fn vkResetFences(device: VkDevice, fenceCount: u32, pFences: [*]const VkFence) VkResult;

// Wrapper struct for cleaner API
pub const Vulkan = struct {
    pub fn createInstance(create_info: *const VkInstanceCreateInfo, allocator: ?*const anyopaque, instance: *VkInstance) VkResult {
        return vkCreateInstance(create_info, allocator, instance);
    }

    pub fn destroyInstance(instance: VkInstance, allocator: ?*const anyopaque) void {
        vkDestroyInstance(instance, allocator);
    }

    pub fn enumeratePhysicalDevices(instance: VkInstance, count: *u32, devices: ?[*]VkPhysicalDevice) VkResult {
        return vkEnumeratePhysicalDevices(instance, count, devices);
    }

    pub fn getPhysicalDeviceProperties(device: VkPhysicalDevice, props: *VkPhysicalDeviceProperties) void {
        vkGetPhysicalDeviceProperties(device, props);
    }

    pub fn getPhysicalDeviceMemoryProperties(device: VkPhysicalDevice, props: *VkPhysicalDeviceMemoryProperties) void {
        vkGetPhysicalDeviceMemoryProperties(device, props);
    }

    pub fn getPhysicalDeviceQueueFamilyProperties(device: VkPhysicalDevice, count: *u32, props: ?[*]VkQueueFamilyProperties) void {
        vkGetPhysicalDeviceQueueFamilyProperties(device, count, props);
    }

    pub fn createDevice(physical_device: VkPhysicalDevice, create_info: *const VkDeviceCreateInfo, allocator: ?*const anyopaque, device: *VkDevice) VkResult {
        return vkCreateDevice(physical_device, create_info, allocator, device);
    }

    pub fn destroyDevice(device: VkDevice, allocator: ?*const anyopaque) void {
        vkDestroyDevice(device, allocator);
    }

    pub fn getDeviceQueue(device: VkDevice, queue_family: u32, queue_index: u32, queue: *VkQueue) void {
        vkGetDeviceQueue(device, queue_family, queue_index, queue);
    }

    pub fn createBuffer(device: VkDevice, create_info: *const VkBufferCreateInfo, allocator: ?*const anyopaque, buffer: *VkBuffer) VkResult {
        return vkCreateBuffer(device, create_info, allocator, buffer);
    }

    pub fn destroyBuffer(device: VkDevice, buffer: VkBuffer, allocator: ?*const anyopaque) void {
        vkDestroyBuffer(device, buffer, allocator);
    }

    pub fn getBufferMemoryRequirements(device: VkDevice, buffer: VkBuffer, requirements: *VkMemoryRequirements) void {
        vkGetBufferMemoryRequirements(device, buffer, requirements);
    }

    pub fn allocateMemory(device: VkDevice, alloc_info: *const VkMemoryAllocateInfo, allocator: ?*const anyopaque, memory: *VkDeviceMemory) VkResult {
        return vkAllocateMemory(device, alloc_info, allocator, memory);
    }

    pub fn freeMemory(device: VkDevice, memory: VkDeviceMemory, allocator: ?*const anyopaque) void {
        vkFreeMemory(device, memory, allocator);
    }

    pub fn bindBufferMemory(device: VkDevice, buffer: VkBuffer, memory: VkDeviceMemory, offset: u64) VkResult {
        return vkBindBufferMemory(device, buffer, memory, offset);
    }

    pub fn mapMemory(device: VkDevice, memory: VkDeviceMemory, offset: u64, size: u64, flags: u32, data: *?*anyopaque) VkResult {
        return vkMapMemory(device, memory, offset, size, flags, data);
    }

    pub fn unmapMemory(device: VkDevice, memory: VkDeviceMemory) void {
        vkUnmapMemory(device, memory);
    }

    pub fn createShaderModule(device: VkDevice, create_info: *const VkShaderModuleCreateInfo, allocator: ?*const anyopaque, shader: *VkShaderModule) VkResult {
        return vkCreateShaderModule(device, create_info, allocator, shader);
    }

    pub fn destroyShaderModule(device: VkDevice, shader: VkShaderModule, allocator: ?*const anyopaque) void {
        vkDestroyShaderModule(device, shader, allocator);
    }

    pub fn createDescriptorSetLayout(device: VkDevice, create_info: *const VkDescriptorSetLayoutCreateInfo, allocator: ?*const anyopaque, layout: *VkDescriptorSetLayout) VkResult {
        return vkCreateDescriptorSetLayout(device, create_info, allocator, layout);
    }

    pub fn destroyDescriptorSetLayout(device: VkDevice, layout: VkDescriptorSetLayout, allocator: ?*const anyopaque) void {
        vkDestroyDescriptorSetLayout(device, layout, allocator);
    }

    pub fn createPipelineLayout(device: VkDevice, create_info: *const VkPipelineLayoutCreateInfo, allocator: ?*const anyopaque, layout: *VkPipelineLayout) VkResult {
        return vkCreatePipelineLayout(device, create_info, allocator, layout);
    }

    pub fn destroyPipelineLayout(device: VkDevice, layout: VkPipelineLayout, allocator: ?*const anyopaque) void {
        vkDestroyPipelineLayout(device, layout, allocator);
    }

    pub fn createComputePipelines(device: VkDevice, cache: VkPipelineCache, count: u32, create_infos: [*]const VkComputePipelineCreateInfo, allocator: ?*const anyopaque, pipelines: [*]VkPipeline) VkResult {
        return vkCreateComputePipelines(device, cache, count, create_infos, allocator, pipelines);
    }

    pub fn destroyPipeline(device: VkDevice, pipeline: VkPipeline, allocator: ?*const anyopaque) void {
        vkDestroyPipeline(device, pipeline, allocator);
    }

    pub fn createDescriptorPool(device: VkDevice, create_info: *const VkDescriptorPoolCreateInfo, allocator: ?*const anyopaque, pool: *VkDescriptorPool) VkResult {
        return vkCreateDescriptorPool(device, create_info, allocator, pool);
    }

    pub fn destroyDescriptorPool(device: VkDevice, pool: VkDescriptorPool, allocator: ?*const anyopaque) void {
        vkDestroyDescriptorPool(device, pool, allocator);
    }

    pub fn allocateDescriptorSets(device: VkDevice, alloc_info: *const VkDescriptorSetAllocateInfo, sets: [*]VkDescriptorSet) VkResult {
        return vkAllocateDescriptorSets(device, alloc_info, sets);
    }

    pub fn updateDescriptorSets(device: VkDevice, write_count: u32, writes: [*]const VkWriteDescriptorSet, copy_count: u32, copies: ?*const anyopaque) void {
        vkUpdateDescriptorSets(device, write_count, writes, copy_count, copies);
    }

    pub fn createCommandPool(device: VkDevice, create_info: *const VkCommandPoolCreateInfo, allocator: ?*const anyopaque, pool: *VkCommandPool) VkResult {
        return vkCreateCommandPool(device, create_info, allocator, pool);
    }

    pub fn destroyCommandPool(device: VkDevice, pool: VkCommandPool, allocator: ?*const anyopaque) void {
        vkDestroyCommandPool(device, pool, allocator);
    }

    pub fn allocateCommandBuffers(device: VkDevice, alloc_info: *const VkCommandBufferAllocateInfo, buffers: [*]VkCommandBuffer) VkResult {
        return vkAllocateCommandBuffers(device, alloc_info, buffers);
    }

    pub fn beginCommandBuffer(buffer: VkCommandBuffer, begin_info: *const VkCommandBufferBeginInfo) VkResult {
        return vkBeginCommandBuffer(buffer, begin_info);
    }

    pub fn endCommandBuffer(buffer: VkCommandBuffer) VkResult {
        return vkEndCommandBuffer(buffer);
    }

    pub fn cmdBindPipeline(buffer: VkCommandBuffer, bind_point: u32, pipeline: VkPipeline) void {
        vkCmdBindPipeline(buffer, bind_point, pipeline);
    }

    pub fn cmdBindDescriptorSets(buffer: VkCommandBuffer, bind_point: u32, layout: VkPipelineLayout, first_set: u32, set_count: u32, sets: [*]const VkDescriptorSet, dynamic_offset_count: u32, dynamic_offsets: ?[*]const u32) void {
        vkCmdBindDescriptorSets(buffer, bind_point, layout, first_set, set_count, sets, dynamic_offset_count, dynamic_offsets);
    }

    pub fn cmdPushConstants(buffer: VkCommandBuffer, layout: VkPipelineLayout, stage_flags: VkShaderStageFlags, offset: u32, size: u32, values: *const anyopaque) void {
        vkCmdPushConstants(buffer, layout, stage_flags, offset, size, values);
    }

    pub fn cmdDispatch(buffer: VkCommandBuffer, x: u32, y: u32, z: u32) void {
        vkCmdDispatch(buffer, x, y, z);
    }

    pub fn queueSubmit(queue: VkQueue, submit_count: u32, submits: [*]const VkSubmitInfo, fence: VkFence) VkResult {
        return vkQueueSubmit(queue, submit_count, submits, fence);
    }

    pub fn queueWaitIdle(queue: VkQueue) VkResult {
        return vkQueueWaitIdle(queue);
    }

    pub fn createFence(device: VkDevice, create_info: *const VkFenceCreateInfo, allocator: ?*const anyopaque, fence: *VkFence) VkResult {
        return vkCreateFence(device, create_info, allocator, fence);
    }

    pub fn destroyFence(device: VkDevice, fence: VkFence, allocator: ?*const anyopaque) void {
        vkDestroyFence(device, fence, allocator);
    }

    pub fn waitForFences(device: VkDevice, fence_count: u32, fences: [*]const VkFence, wait_all: u32, timeout: u64) VkResult {
        return vkWaitForFences(device, fence_count, fences, wait_all, timeout);
    }

    pub fn resetFences(device: VkDevice, fence_count: u32, fences: [*]const VkFence) VkResult {
        return vkResetFences(device, fence_count, fences);
    }
};
