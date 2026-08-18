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

--- nil means the file does not exist; a file that exists but is not valid
--- JSON raises a specific error instead of being mistaken for a missing tool.
local function read_json(path)
    if not file.exists(path) then
        return nil
    end
    local ok, decoded = pcall(json.decode, file.read(path))
    if not ok then
        error("catalog file is not valid JSON: " .. path)
    end
    return decoded
end

--- Quote one value for safe use inside a shell command string.
--- Wraps the value in single quotes; embedded single quotes are escaped.
--- Every hook value that reaches cmd.exec must pass through this.
function M.shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

--- A tool name may only contain lowercase letters, digits, dot, underscore,
--- and hyphen (the same rule the catalog validator enforces), so it can never
--- change the meaning of a file path or URL it is inserted into.
local function check_tool_name(tool)
    if type(tool) ~= "string" or tool:match("^[%l%d][%l%d%._%-]*$") == nil then
        error("invalid tool name: " .. tostring(tool))
    end
end

--- Load catalog/<tool>/tool.json; error if the tool is not in the catalog.
function M.load_tool(tool)
    check_tool_name(tool)
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
    check_tool_name(tool)
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

--- A Nexus base URL must be a plain http(s) URL with no characters that
--- could alter a shell command or smuggle extra URL components.
local function check_nexus_url(url, origin)
    if type(url) ~= "string"
        or url:match("^https?://[%w%-%._~:/%%%+]+$") == nil then
        error("refusing unsafe nexus_url from " .. origin .. ": " .. tostring(url))
    end
    return url
end

--- Nexus base URL: per-tool option (from [tool_alias] bracketed opts or [tools])
--- wins over the default bundled in config/defaults.json.
function M.nexus_base(options)
    if options ~= nil and options.nexus_url ~= nil and options.nexus_url ~= "" then
        return check_nexus_url(options.nexus_url, "tool option")
    end
    local defaults = read_json(file.join_path(M.plugin_dir(), "config", "defaults.json"))
    if defaults == nil or defaults.nexus_url == nil then
        error("mise-vault: no nexus_url configured (option or config/defaults.json)")
    end
    return check_nexus_url(defaults.nexus_url, "config/defaults.json")
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
