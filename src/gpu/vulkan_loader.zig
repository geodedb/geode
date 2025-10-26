const std = @import("std");
const vk = @import("vulkan_ffi.zig");

// Re-export all Vulkan types and constants
pub const VK_SUCCESS = vk.VK_SUCCESS;
pub const VK_ERROR_OUT_OF_HOST_MEMORY = vk.VK_ERROR_OUT_OF_HOST_MEMORY;
pub const VK_ERROR_OUT_OF_DEVICE_MEMORY = vk.VK_ERROR_OUT_OF_DEVICE_MEMORY;
pub const VK_ERROR_INITIALIZATION_FAILED = vk.VK_ERROR_INITIALIZATION_FAILED;
pub const VK_ERROR_DEVICE_LOST = vk.VK_ERROR_DEVICE_LOST;
pub const VK_ERROR_MEMORY_MAP_FAILED = vk.VK_ERROR_MEMORY_MAP_FAILED;

pub const VkInstance = vk.VkInstance;
pub const VkPhysicalDevice = vk.VkPhysicalDevice;
pub const VkDevice = vk.VkDevice;
pub const VkQueue = vk.VkQueue;
pub const VkCommandPool = vk.VkCommandPool;
pub const VkCommandBuffer = vk.VkCommandBuffer;
pub const VkBuffer = vk.VkBuffer;
pub const VkDeviceMemory = vk.VkDeviceMemory;
pub const VkShaderModule = vk.VkShaderModule;
pub const VkPipeline = vk.VkPipeline;
pub const VkPipelineLayout = vk.VkPipelineLayout;
pub const VkDescriptorSetLayout = vk.VkDescriptorSetLayout;
pub const VkDescriptorPool = vk.VkDescriptorPool;
pub const VkDescriptorSet = vk.VkDescriptorSet;
pub const VkFence = vk.VkFence;
pub const VkResult = vk.VkResult;

pub const VkPhysicalDeviceProperties = vk.VkPhysicalDeviceProperties;
pub const VkPhysicalDeviceMemoryProperties = vk.VkPhysicalDeviceMemoryProperties;
pub const VkQueueFamilyProperties = vk.VkQueueFamilyProperties;
pub const VkMemoryRequirements = vk.VkMemoryRequirements;

pub const VkInstanceCreateInfo = vk.VkInstanceCreateInfo;
pub const VkDeviceCreateInfo = vk.VkDeviceCreateInfo;
pub const VkDeviceQueueCreateInfo = vk.VkDeviceQueueCreateInfo;
pub const VkBufferCreateInfo = vk.VkBufferCreateInfo;
pub const VkMemoryAllocateInfo = vk.VkMemoryAllocateInfo;
pub const VkShaderModuleCreateInfo = vk.VkShaderModuleCreateInfo;
pub const VkPipelineLayoutCreateInfo = vk.VkPipelineLayoutCreateInfo;
pub const VkComputePipelineCreateInfo = vk.VkComputePipelineCreateInfo;
pub const VkDescriptorSetLayoutCreateInfo = vk.VkDescriptorSetLayoutCreateInfo;
pub const VkDescriptorPoolCreateInfo = vk.VkDescriptorPoolCreateInfo;
pub const VkDescriptorSetAllocateInfo = vk.VkDescriptorSetAllocateInfo;
pub const VkCommandPoolCreateInfo = vk.VkCommandPoolCreateInfo;
pub const VkCommandBufferAllocateInfo = vk.VkCommandBufferAllocateInfo;
pub const VkCommandBufferBeginInfo = vk.VkCommandBufferBeginInfo;
pub const VkSubmitInfo = vk.VkSubmitInfo;
pub const VkFenceCreateInfo = vk.VkFenceCreateInfo;
pub const VkWriteDescriptorSet = vk.VkWriteDescriptorSet;
pub const VkDescriptorBufferInfo = vk.VkDescriptorBufferInfo;
pub const VkPipelineShaderStageCreateInfo = vk.VkPipelineShaderStageCreateInfo;
pub const VkDescriptorSetLayoutBinding = vk.VkDescriptorSetLayoutBinding;
pub const VkPushConstantRange = vk.VkPushConstantRange;
pub const VkDescriptorPoolSize = vk.VkDescriptorPoolSize;

pub const VkBufferUsageFlags = vk.VkBufferUsageFlags;
pub const VkMemoryPropertyFlags = vk.VkMemoryPropertyFlags;
pub const VkQueueFlags = vk.VkQueueFlags;

pub const VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
pub const VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO = vk.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
pub const VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
pub const VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
pub const VK_STRUCTURE_TYPE_SUBMIT_INFO = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO;
pub const VK_STRUCTURE_TYPE_FENCE_CREATE_INFO = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
pub const VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
pub const VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;

pub const VK_BUFFER_USAGE_STORAGE_BUFFER_BIT = vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
pub const VK_BUFFER_USAGE_TRANSFER_SRC_BIT = vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
pub const VK_BUFFER_USAGE_TRANSFER_DST_BIT = vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT;

pub const VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT = vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT;
pub const VK_MEMORY_PROPERTY_HOST_COHERENT_BIT = vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
pub const VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT = vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT;

pub const VK_QUEUE_COMPUTE_BIT = vk.VK_QUEUE_COMPUTE_BIT;

pub const VK_DESCRIPTOR_TYPE_STORAGE_BUFFER = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;

pub const VK_SHADER_STAGE_COMPUTE_BIT = vk.VK_SHADER_STAGE_COMPUTE_BIT;

pub const VK_PIPELINE_BIND_POINT_COMPUTE = vk.VK_PIPELINE_BIND_POINT_COMPUTE;

pub const VK_COMMAND_BUFFER_LEVEL_PRIMARY = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY;

pub const VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;

pub const VkApplicationInfo = vk.VkApplicationInfo;
pub const VK_STRUCTURE_TYPE_APPLICATION_INFO = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO;
pub const VK_API_VERSION_1_0 = vk.VK_API_VERSION_1_0;

pub const VK_SHARING_MODE_EXCLUSIVE = vk.VK_SHARING_MODE_EXCLUSIVE;
pub const VK_SHARING_MODE_CONCURRENT = vk.VK_SHARING_MODE_CONCURRENT;

pub const VK_NULL_HANDLE = vk.VK_NULL_HANDLE;

pub const Vulkan = vk.Vulkan;
