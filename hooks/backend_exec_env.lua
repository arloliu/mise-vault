--- Environment for an installed tool: bin dirs on PATH plus any
--- tool-declared env vars (e.g. GOROOT for runtime distributions).
function PLUGIN:BackendExecEnv(ctx)
    local common = require("lib/common")
    local file = require("file")

    local tool = common.load_tool(ctx.tool)

    local env_vars = {}

    -- Types built by their own ecosystem's installer rather than unpacked
    -- from a Nexus artifact; the binary always lands in install_path/bin
    -- (see hooks/backend_install.lua). cargo joins this set in a later phase.
    local SOURCE_BUILT_TYPES = { go = true, npm = true, pypi = true }

    if SOURCE_BUILT_TYPES[tool.type] then
        table.insert(env_vars, { key = "PATH", value = file.join_path(ctx.install_path, "bin") })
    else
        local platform = common.platform()
        local pconf = tool.platforms[platform]
        if pconf == nil then
            error(ctx.tool .. " " .. ctx.version .. " is not available for " .. platform)
        end

        local bin_paths = pconf.bin_paths or { "." }
        local rendered = {}
        for _, p in ipairs(bin_paths) do
            if p == "." then
                table.insert(rendered, ctx.install_path)
            else
                table.insert(rendered, file.join_path(ctx.install_path, p))
            end
        end
        table.insert(env_vars, { key = "PATH", value = table.concat(rendered, ":") })
    end

    -- sort the keys so the emitted list is deterministic (pairs() order is not)
    local env = tool.env or {}
    local keys = {}
    for k in pairs(env) do
        table.insert(keys, k)
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
        table.insert(env_vars, {
            key = k,
            value = common.render(env[k], { install_path = ctx.install_path, version = ctx.version }),
        })
    end

    return { env_vars = env_vars }
end
