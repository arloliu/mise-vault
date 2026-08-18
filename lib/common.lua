--- Shared helpers for mise-vault hooks.
--- Fail-closed principle: every lookup that misses raises an explicit error;
--- no fallback to public services may ever be added here.
local file = require("file")
local json = require("json")

local M = {}

--- Root of this plugin's checkout (catalog lives inside it).
function M.plugin_dir()
    return RUNTIME.pluginDirPath
end

--- Canonical platform id, e.g. "linux-amd64" (RUNTIME.osType/archType already use these names).
function M.platform()
    return RUNTIME.osType .. "-" .. RUNTIME.archType
end

local function read_json(path)
    if not file.exists(path) then
        return nil
    end
    return json.decode(file.read(path))
end

--- Load catalog/<tool>/tool.json; error if the tool is not in the catalog.
function M.load_tool(tool)
    local path = file.join_path(M.plugin_dir(), "catalog", tool, "tool.json")
    local t = read_json(path)
    if t == nil then
        error("tool '" .. tool .. "' is not available in the company tool catalog")
    end
    return t
end

--- Load catalog/<tool>/versions.json; error if missing.
--- Schema: ordered ARRAY, oldest-approved first (order is authoritative;
--- CI validates it — the plugin never re-sorts):
---   [ { "version": "2.12.1", "platforms": { "linux-amd64": { "sha256": "..." } } }, ... ]
function M.load_versions(tool)
    local path = file.join_path(M.plugin_dir(), "catalog", tool, "versions.json")
    local v = read_json(path)
    if v == nil then
        error("tool '" .. tool .. "' is not available in the company tool catalog")
    end
    return v
end

--- Find one version record in the array; nil if not approved.
function M.find_version(versions, version)
    for _, rec in ipairs(versions) do
        if rec.version == version then
            return rec
        end
    end
    return nil
end

--- Nexus base URL: per-tool option (from [tool_alias] bracketed opts or [tools])
--- wins over the default bundled in config/defaults.json.
function M.nexus_base(options)
    if options ~= nil and options.nexus_url ~= nil and options.nexus_url ~= "" then
        return options.nexus_url
    end
    local defaults = read_json(file.join_path(M.plugin_dir(), "config", "defaults.json"))
    if defaults == nil or defaults.nexus_url == nil then
        error("mise-vault: no nexus_url configured (option or config/defaults.json)")
    end
    return defaults.nexus_url
end

--- Substitute {version} / {install_path} placeholders.
function M.render(template, vars)
    local out = template
    for k, v in pairs(vars) do
        out = out:gsub("{" .. k .. "}", v)
    end
    return out
end

return M
