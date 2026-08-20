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

--- Validate an npm package name before it reaches a shell command: an
--- optional "@scope/" prefix, then lowercase [a-z0-9._-] segments, capped
--- at npm's own 214-character limit.
--- The "/" is the only path separator allowed anywhere in the value,
--- and only as the single scope separator.
--- This is defense in depth: the catalog validator already enforces the
--- same rule, but a runtime check never trusts a file on disk blindly.
--- Deliberately narrower than npm's own rules (a shell-safety envelope,
--- not a full syntax validator): a value can match here and still not
--- exist in the registry — scripts/add-version probes for that.
function M.check_npm_package(package, label)
    if type(package) ~= "string" or package == "" or #package > 214 then
        error(label .. " is not a valid npm package name: " .. tostring(package))
    end
    local name = package
    if package:sub(1, 1) == "@" then
        local slash = package:find("/", 1, true)
        if slash == nil then
            error(label .. " is not a valid npm package name (a scoped name needs " ..
                  "/name after @scope): " .. package)
        end
        local scope = package:sub(2, slash - 1)
        if scope == "" or scope:match("^[%l%d][%l%d%._%-]*$") == nil then
            error(label .. " has an invalid npm scope: " .. package)
        end
        if package:find("/", slash + 1, true) ~= nil then
            error(label .. " has more than one / (only the scope separator is allowed): " ..
                  package)
        end
        name = package:sub(slash + 1)
    end
    if name == "" or name:match("^[%l%d][%l%d%._%-]*$") == nil then
        error(label .. " is not a valid npm package name: " .. tostring(package))
    end
    return package
end

--- Validate a PyPI package name before it reaches a shell command: the
--- PEP 503 normalized form only (lowercase letters, digits, and single
--- hyphens between segments; no leading, trailing, or doubled hyphen).
--- The catalog stores only the normalized form; scripts/add-version
--- refuses a non-normalized input instead of silently rewriting it.
function M.check_pypi_package(package, label)
    if type(package) ~= "string" or package == ""
        or package:match("^[%l%d%-]+$") == nil
        or package:sub(1, 1) == "-" or package:sub(-1) == "-"
        or package:find("--", 1, true) ~= nil then
        error(label .. " is not a valid PyPI package name (expected the PEP 503 " ..
              "normalized form): " .. tostring(package))
    end
    return package
end

--- Validate the optional "bin" field shared by npm, pypi, and cargo: the
--- executable name the plugin looks for after install and exposes on PATH.
--- It becomes part of a filesystem path, so the grammar is narrow and
--- shell-safe, and capped at 64 characters.
function M.check_bin_name(bin, label)
    if type(bin) ~= "string" or bin == "" or #bin > 64
        or bin:match("^[%l%d][%l%d%._%-]*$") == nil then
        error(label .. " is not a valid binary name: " .. tostring(bin))
    end
    return bin
end

--- Validate a crates.io crate name before it reaches a shell command:
--- an alphabetic first character, then lowercase letters, digits,
--- underscore, and hyphen, capped at crates.io's own 64-character limit.
--- This is defense in depth: the catalog validator already enforces the
--- same rule, but a runtime check never trusts a file on disk blindly.
--- Deliberately narrower than crates.io's own rules (a shell-safety
--- envelope, not a full syntax validator): historic uppercase crate names
--- cannot be approved as-is, and a value can match here and still not
--- exist in the registry — scripts/add-version probes for that.
function M.check_crate_name(crate, label)
    if type(crate) ~= "string" or crate == "" or #crate > 64
        or crate:match("^%l[%l%d_%-]*$") == nil then
        error(label .. " is not a valid crate name: " .. tostring(crate))
    end
    return crate
end

--- Lowercase semver envelope shared by npm and cargo versions
--- ("major.minor.patch" plus optional "-prerelease" and "+build" parts).
--- This is an envelope, not a semver implementation: it does not enforce
--- semver's leading-zero or empty-identifier rules, and it does not accept
--- uppercase (npm/cargo prerelease segments may legally contain uppercase,
--- e.g. "1.0.0-RC.1", but such versions cannot be approved as-is — widening
--- this is a small reviewed change). scripts/add-version's registry probe
--- is the real semantic check.
function M.check_semver_envelope(version, label)
    if type(version) ~= "string" or version == "" then
        error(label .. " is not a valid version: " .. tostring(version))
    end
    local rest = version:match("^%d+%.%d+%.%d+(.*)$")
    if rest == nil then
        error(label .. " is not a valid version (expected a lowercase " ..
              "major.minor.patch envelope): " .. version)
    end
    if rest ~= "" then
        local ok = false
        if rest:match("^%-[%l%d%.%-]+%+[%l%d%.%-]+$") ~= nil then
            ok = true
        elseif rest:match("^%-[%l%d%.%-]+$") ~= nil then
            ok = true
        elseif rest:match("^%+[%l%d%.%-]+$") ~= nil then
            ok = true
        end
        if not ok then
            error(label .. " is not a valid version (expected a lowercase " ..
                  "major.minor.patch envelope): " .. version)
        end
    end
    return version
end

--- PEP 440 envelope for PyPI versions, covering the common shapes only
--- (epochs and legacy version forms are deliberately not representable).
--- Consumes the string piece by piece — release segments, then an optional
--- pre-release (a/b/rc), post-release, dev-release, and local version —
--- and errors if anything is left over, to the same effect as the anchored
--- regex used in the schemas and scripts/validate-catalog.
function M.check_pep440_envelope(version, label)
    if type(version) ~= "string" or version == "" then
        error(label .. " is not a valid PyPI version: " .. tostring(version))
    end
    local fail = function()
        error(label .. " is not a valid PyPI version (expected a PEP 440 envelope): " .. version)
    end
    local s = version
    local rel = s:match("^%d+")
    if rel == nil then
        fail()
    end
    s = s:sub(#rel + 1)
    while true do
        local seg = s:match("^%.%d+")
        if seg == nil then
            break
        end
        s = s:sub(#seg + 1)
    end
    local pre = s:match("^a%d+") or s:match("^b%d+") or s:match("^rc%d+")
    if pre ~= nil then
        s = s:sub(#pre + 1)
    end
    local post = s:match("^%.post%d+")
    if post ~= nil then
        s = s:sub(#post + 1)
    end
    local dev = s:match("^%.dev%d+")
    if dev ~= nil then
        s = s:sub(#dev + 1)
    end
    if s:sub(1, 1) == "+" then
        local rest = s:sub(2)
        local seg = rest:match("^[%l%d]+")
        if seg == nil then
            fail()
        end
        rest = rest:sub(#seg + 1)
        while true do
            local nxt = rest:match("^%.[%l%d]+")
            if nxt == nil then
                break
            end
            rest = rest:sub(#nxt + 1)
        end
        s = rest
    end
    if s ~= "" then
        fail()
    end
    return version
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
