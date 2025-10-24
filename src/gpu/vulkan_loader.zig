const std = @import("std");

const c = @cImport({
    @cInclude("vulkan/vulkan.h");
});

pub const Vulkan = struct {
    pub fn enumerate_physical_devices(instance: c.VkInstance, pCount: *c.uint32_t, pPhysicalDevices: ?*c.VkPhysicalDevice) c.VkResult {
        return c.vkEnumeratePhysicalDevices(instance, pCount, pPhysicalDevices);
    }

    pub fn get_physical_device_properties(device: c.VkPhysicalDevice, props: *c.VkPhysicalDeviceProperties) void {
        c.vkGetPhysicalDeviceProperties(device, props);
    }

    // Minimal helper to create VkInstance (very permissive)
    pub fn create_instance() ?c.VkInstance {
        var create_info: c.VkInstanceCreateInfo = undefined;
        create_info.sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        create_info.pNext = null;
        create_info.flags = 0;
        create_info.pApplicationInfo = null;
        create_info.enabledLayerCount = 0;
        create_info.ppEnabledLayerNames = null;
        create_info.enabledExtensionCount = 0;
        create_info.ppEnabledExtensionNames = null;
        var instance: c.VkInstance = null;
        if (c.vkCreateInstance(&create_info, null, &instance) != c.VK_SUCCESS) return null;
        return instance;
    }
};
