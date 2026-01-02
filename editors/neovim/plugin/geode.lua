-- Geode GQL Plugin Entry Point
-- Auto-loads when Neovim starts

-- Prevent double loading
if vim.g.loaded_geode then
    return
end
vim.g.loaded_geode = true

-- Minimum Neovim version check
if vim.fn.has("nvim-0.8") == 0 then
    vim.api.nvim_err_writeln("Geode plugin requires Neovim 0.8 or higher")
    return
end

-- Register filetype detection
vim.filetype.add({
    extension = {
        gql = "gql",
        gcypher = "gql",
        cypher = "gql",
        pgql = "gql",
    },
    pattern = {
        [".*%.gql%.j2"] = "gql", -- Jinja2 templates
        [".*%.cypher%.j2"] = "gql",
    },
})

-- Create user commands (available before setup() is called)
vim.api.nvim_create_user_command("GeodeSetup", function(opts)
    local config = {}
    if opts.args ~= "" then
        -- Parse simple key=value arguments
        for pair in opts.args:gmatch("%S+") do
            local key, value = pair:match("([^=]+)=(.+)")
            if key and value then
                -- Handle nested keys like lsp.enabled
                local keys = vim.split(key, ".", { plain = true })
                local tbl = config
                for i = 1, #keys - 1 do
                    tbl[keys[i]] = tbl[keys[i]] or {}
                    tbl = tbl[keys[i]]
                end
                -- Try to convert value to appropriate type
                if value == "true" then
                    tbl[keys[#keys]] = true
                elseif value == "false" then
                    tbl[keys[#keys]] = false
                elseif tonumber(value) then
                    tbl[keys[#keys]] = tonumber(value)
                else
                    tbl[keys[#keys]] = value
                end
            end
        end
    end
    require("geode").setup(config)
end, {
    nargs = "*",
    desc = "Setup Geode plugin with optional configuration",
})

-- Lazy-load the main module
vim.api.nvim_create_autocmd("FileType", {
    pattern = { "gql", "cypher", "gcypher", "pgql" },
    callback = function()
        -- Check if user has called setup
        local geode = require("geode")
        if not vim.g.geode_setup_called then
            -- Auto-setup with defaults if user hasn't configured
            geode.setup()
            vim.g.geode_setup_called = true
        end
    end,
    once = true,
})
