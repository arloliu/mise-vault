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
--- CI validates it — the plugin never re-sorts).
--- Artifact tools:
---   [ { "version": "2.12.1", "platforms": { "linux-amd64": { "sha256": "..." } } }, ... ]
--- Go tools (h1 optional — see hooks/backend_install.lua):
---   [ { "version": "0.2.0", "h1": "h1:..." }, ... ]
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

--- A base URL (Nexus, or the go proxy) must be a plain http(s) URL with no
--- characters that could alter a shell command or smuggle extra URL components.
local function check_base_url(url, label, origin)
    if type(url) ~= "string"
        or url:match("^https?://[%w%-%._~:/%%%+]+$") == nil then
        error("refusing unsafe " .. label .. " from " .. origin .. ": " .. tostring(url))
    end
    return url
end

--- Shared resolution ladder for a base URL: env var, then per-tool option,
--- then config/defaults.json.
--- Used by both Nexus and the go proxy so the two channels behave identically.
local function resolve_base_url(env_var, option_key, defaults_key, label, options)
    local env_url = os.getenv(env_var)
    if env_url ~= nil and env_url ~= "" then
        return check_base_url(env_url, label, env_var .. " environment variable")
    end
    if options ~= nil and options[option_key] ~= nil and options[option_key] ~= "" then
        return check_base_url(options[option_key], label, "tool option")
    end
    local defaults = read_json(file.join_path(M.plugin_dir(), "config", "defaults.json"))
    if defaults == nil or defaults[defaults_key] == nil then
        error("mise-vault: no " .. defaults_key .. " configured (option or config/defaults.json)")
    end
    return check_base_url(defaults[defaults_key], label, "config/defaults.json")
end

--- Nexus base URL, first match wins:
---   1. MISE_VAULT_NEXUS_URL environment variable
---      (a shell export, or an [env] entry in a trusted mise.toml)
---   2. per-tool option nexus_url (from [tool_alias] bracketed opts or [tools])
---   3. the default bundled in config/defaults.json
function M.nexus_base(options)
    return resolve_base_url("MISE_VAULT_NEXUS_URL", "nexus_url", "nexus_url", "nexus_url", options)
end

--- Go proxy base URL for go-installed tools.
--- Same three-channel ladder as nexus_base, kept separate because a go tool
--- must never inherit the developer's own GOPROXY:
---   1. MISE_VAULT_GOPROXY_URL environment variable
---      (a shell export, or an [env] entry in a trusted mise.toml)
---   2. per-tool option goproxy_url (from [tool_alias] bracketed opts or [tools])
---   3. the default bundled in config/defaults.json
function M.goproxy_base(options)
    return resolve_base_url("MISE_VAULT_GOPROXY_URL", "goproxy_url", "goproxy_url", "goproxy_url", options)
end

--- Validate a go module path (or module root) before it reaches a shell
--- command: lowercase [a-z0-9._~/-] only, no leading or trailing slash,
--- no "..", at least one slash, a lowercase host-looking first segment
--- (contains a dot), and no dots-only path segment ("." or ".." as a
--- segment would change which path the module name resolves to).
--- Uppercase module paths are refused: the go proxy protocol needs them
--- escaped, which nothing here implements, so they fail closed instead.
--- This is defense in depth: the catalog validator already enforces the
--- same rule, but a runtime check never trusts a file on disk blindly.
function M.check_module_path(module, label)
    if type(module) ~= "string" or module == ""
        or module:match("^[%l%d%._~/%-]+$") == nil
        or module:find("..", 1, true) ~= nil
        or module:sub(1, 1) == "/" or module:sub(-1) == "/"
        or module:find("//", 1, true) ~= nil then
        error(label .. " is not a valid go module path: " .. tostring(module))
    end
    local first = module:match("^([^/]+)/")
    if first == nil or first:match("^[%l%d][%l%d%.%-]*$") == nil or first:find("%.") == nil then
        error(label .. " does not start with a lowercase host-looking segment: " .. tostring(module))
    end
    -- go refuses path elements that begin or end with a dot;
    -- rejecting them here keeps a bad catalog entry from failing
    -- only deep inside the go command (this also covers "." and "..")
    for segment in module:gmatch("/([^/]+)") do
        if segment:match("^[%l%d_~%-]") == nil or segment:match("[%l%d_~%-]$") == nil then
            error(label .. " has a path segment that starts or ends with a dot: " .. tostring(module))
        end
    end
    return module
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
