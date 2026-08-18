--- mise install <tool>@<version>:
---   catalog lookup -> platform resolution -> Nexus URL -> download (curl -n)
---   -> mandatory SHA-256 verification -> extract -> install_path.
--- Fail-closed: any miss or mismatch aborts with a specific error;
--- there is no fallback to public services, ever.
function PLUGIN:BackendInstall(ctx)
    local common = require("lib/common")
    local file = require("file")
    local cmd = require("cmd")
    local archiver = require("archiver")
    local strings = require("strings")

    local tool = common.load_tool(ctx.tool)
    local versions = common.load_versions(ctx.tool)
    local platform = common.platform()

    -- 1. version must be approved
    local vrec = common.find_version(versions, ctx.version)
    if vrec == nil then
        error(ctx.tool .. " " .. ctx.version .. " is not an approved version")
    end

    -- 2. platform must be supported by both tool metadata and version record
    local pconf = tool.platforms[platform]
    local psha = vrec.platforms[platform]
    if pconf == nil or psha == nil then
        error(ctx.tool .. " " .. ctx.version .. " is not available for " .. platform)
    end

    -- 3. construct Nexus URL (never any other host)
    -- The rendered artifact must be a plain file name: no path separators,
    -- no shell metacharacters, not a dot-only name.
    -- Anything else could move the download destination or alter the download command.
    local artifact = common.render(pconf.artifact, { version = ctx.version })
    if artifact:match("^[%w%._%+%-]+$") == nil or artifact:match("^%.+$") ~= nil then
        error("catalog artifact for " .. ctx.tool .. " is not a plain file name: " .. artifact)
    end
    local url = common.nexus_base(ctx.options) .. "/" .. ctx.tool .. "/" .. ctx.version .. "/" .. artifact

    -- 4. download via curl (rides ~/.netrc with -n; Lua http module has no netrc support)
    -- --max-redirs 0: a redirect could send the request to a host other than
    -- the configured Nexus, so any redirect aborts the download.
    local q = common.shell_quote
    local dest = file.join_path(ctx.download_path, artifact)
    local dl = cmd.exec("curl -fsSL --max-redirs 0 -n --retry 2 -o " .. q(dest) .. " " .. q(url) ..
                        " 2>&1 && echo CURL_OK")
    if not strings.contains(dl, "CURL_OK") then
        local detail = strings.split(strings.trim_space(dl), "\n")[1] or ""
        if detail ~= "" then
            detail = " — " .. detail
        end
        error("approved Nexus artifact could not be downloaded" ..
              " (server error, or a redirect, which is refused): " .. url .. detail ..
              " (authentication rides ~/.netrc for the Nexus host)")
    end

    -- 5. mandatory SHA-256 verification
    local hasher = "sha256sum"
    if RUNTIME.osType == "darwin" then
        hasher = "shasum -a 256"
    end
    local out = cmd.exec(hasher .. " " .. q(dest))
    local got = strings.split(strings.trim_space(out), " ")[1]
    if got ~= psha.sha256 then
        error("SHA-256 verification failed for " .. artifact ..
              " (expected " .. psha.sha256 .. ", got " .. tostring(got) .. ")")
    end

    -- 6. extract into install_path
    local strip = pconf.strip_components or 0
    if pconf.format == "binary" then
        local target = file.join_path(ctx.install_path, ctx.tool)
        cmd.exec("mkdir -p " .. q(ctx.install_path) .. " && cp " .. q(dest) .. " " .. q(target) ..
                 " && chmod +x " .. q(target))
    else
        archiver.decompress(dest, ctx.install_path, { strip_components = strip })
    end

    return {}
end
