--- mise install <tool>@<version>:
---   artifact tools: catalog lookup -> platform resolution -> Nexus URL ->
---     download (curl -n) -> mandatory SHA-256 verification -> extract -> install_path.
---   go tools: catalog lookup -> "go install <module>@v<version>" against the
---     plugin-controlled go proxy, with an optional module checksum check first.
--- Fail-closed: any miss or mismatch aborts with a specific error;
--- there is no fallback to public services, ever.

--- Install a tool built with "go install". Runs before the platform lookup:
--- go tools carry no platforms entry at all, they run wherever an approved
--- go toolchain is already installed.
local function install_go_tool(ctx, tool, vrec, common, cmd, strings, json)
    local file = require("file")
    local q = common.shell_quote

    -- The catalog validator already enforces this shape; checked again here
    -- so a hand-edited or compromised file on disk can never reach a shell
    -- command unvalidated (the same defense-in-depth the artifact name gets).
    common.check_module_path(tool.module, "module")
    local module_root = tool.module
    if tool.module_root ~= nil then
        common.check_module_path(tool.module_root, "module_root")
        module_root = tool.module_root
        local is_prefix = module_root == tool.module
            or tool.module:sub(1, #module_root + 1) == (module_root .. "/")
        if not is_prefix then
            error("module_root is not a prefix of module for " .. ctx.tool)
        end
    end

    -- A go toolchain must already be installed:
    -- bootstrapping go itself and a go tool in one pass is not supported.
    -- Any binary named "go" is not enough —
    -- the toolchain's reported version must be in the approved go version
    -- list, the same catalog gate every other install obeys.
    -- (This binds the version string, not the binary's provenance:
    -- a system-installed go at an approved version is accepted.)
    -- GOTOOLCHAIN=local even for the version probes:
    -- a developer's GOTOOLCHAIN setting could otherwise make the probe
    -- itself download a different toolchain.
    local approved_ok, approved_go = pcall(common.load_versions, "go")
    if not approved_ok then
        error(ctx.tool .. " is a go-installed tool, which needs an approved go toolchain, " ..
              "but the catalog has no go entry")
    end
    local go_bin = nil
    local gv = cmd.exec("GOTOOLCHAIN=local go version 2>&1 || true")
    local path_release = gv:match("go version go([^%s]+)")
    if path_release ~= nil and common.find_version(approved_go, path_release) ~= nil then
        go_bin = "go"
    else
        -- mise strips its own managed tool paths from PATH while a hook
        -- runs, so a "mise use go" toolchain is invisible there
        -- (verified against mise v2026.8.8) —
        -- look for an approved go in mise's install tree directly,
        -- newest approved version first.
        -- ctx.install_path is <installs root>/<this tool>/<version>.
        local installs_root = ctx.install_path:match("^(.*)/[^/]+/[^/]+$")
        for i = #approved_go, 1, -1 do
            local candidate = installs_root .. "/go/" .. approved_go[i].version .. "/bin/go"
            if file.exists(candidate) then
                local cv = cmd.exec("GOTOOLCHAIN=local " .. q(candidate) .. " version 2>&1 || true")
                if cv:match("go version go([^%s]+)") == approved_go[i].version then
                    go_bin = candidate
                    break
                end
            end
        end
    end
    if go_bin == nil then
        local seen = ""
        if path_release ~= nil then
            seen = " (the go on PATH is go" .. path_release .. ", which is not approved)"
        end
        error(ctx.tool .. " is a go-installed tool but no approved go toolchain was found" ..
              seen .. " — install one first (for example: mise use go@<version>), then retry")
    end

    local proxy = common.goproxy_base(ctx.options)
    local tag = "v" .. ctx.version

    -- Environment for every go fetch/build below.
    -- Setting GOPROXY alone is not enough —
    -- the inherited environment could still redirect or alter the operation:
    --   GONOPROXY=none / GOPRIVATE=  a developer's GOPRIVATE (which doubles
    --     as the GONOPROXY default) would make matching modules bypass the
    --     proxy and fetch from version control directly
    --   GOSUMDB=off  the public checksum database is unreachable from the
    --     private network; the catalog h1 (when present) is the check
    --   GOTOOLCHAIN=local  never download a different go toolchain
    --   GOFLAGS is pinned per command below so local flag defaults
    --     (overlays, alternate tool execution) cannot change what is built
    --   GOENV=off  settings written with "go env -w" must not leak in
    --   GOMODCACHE / GOPATH / GOCACHE  fresh per-install caches, shared by
    --     the checksum preflight and the build: go trusts cached module
    --     content and cached build results without rehashing them, so an
    --     inherited (or tampered) cache could serve content that still
    --     reports the catalogued checksum, or a compiled result that was
    --     never built from the verified source
    --   GOCACHEPROG cleared  an external cache program could do the same
    -- (-modcacherw below keeps the throwaway module cache deletable)
    local modcache = file.join_path(ctx.download_path, "gomodcache")
    local gopath = file.join_path(ctx.download_path, "gopath")
    local buildcache = file.join_path(ctx.download_path, "gocache")
    -- the download directory can survive between installs (mise's
    -- always_keep_download); a leftover cache is exactly what the fresh-cache
    -- guarantee exists to prevent, so any previous contents are removed first
    -- (module caches are created with -modcacherw below, so a leftover one
    -- is writable and removable; the existence check makes a failed removal
    -- abort instead of silently reusing whatever survived)
    cmd.exec("rm -rf " .. q(modcache) .. " " .. q(gopath) .. " " .. q(buildcache) ..
             " 2>&1 || true")
    if file.exists(modcache) or file.exists(gopath) or file.exists(buildcache) then
        error("could not clear the previous go caches under " .. ctx.download_path ..
              " — remove them manually, then retry")
    end
    local goenv = "GOPROXY=" .. q(proxy) ..
        " GONOPROXY=none GOPRIVATE= GOSUMDB=off GOTOOLCHAIN=local GOENV=off" ..
        " GOCACHEPROG= GOMODCACHE=" .. q(modcache) .. " GOPATH=" .. q(gopath) ..
        " GOCACHE=" .. q(buildcache)

    if vrec.h1 ~= nil then
        -- "go install" resolves a package to the LONGEST module path that
        -- exists at the requested version.
        -- If any module nested below module_root also exists at this
        -- version, the dirhash below would verify one module while go
        -- builds another — refuse instead of verifying the wrong thing.
        if module_root ~= tool.module then
            local candidate = module_root
            for segment in tool.module:sub(#module_root + 2):gmatch("[^/]+") do
                candidate = candidate .. "/" .. segment
                local probe = proxy .. "/" .. candidate .. "/@v/" .. tag .. ".info"
                local code = strings.trim_space(cmd.exec(
                    "curl -sS -o /dev/null --max-redirs 0 -n -w '%{http_code}' " ..
                    q(probe) .. " 2>/dev/null || true"))
                if code == "200" then
                    error("module " .. candidate .. " also exists at " .. tag ..
                          " and would shadow module_root " .. module_root ..
                          " during go install, so the recorded checksum cannot bind to " ..
                          "what gets built — fix module_root in the catalog")
                elseif code ~= "404" and code ~= "410" then
                    error("could not probe the go proxy for nested modules (HTTP " ..
                          tostring(code) .. "): " .. probe)
                end
            end
        end

        -- Optional dirhash verification: trust-but-verify the module content
        -- against the go proxy before building.
        -- "go mod download -json" can exit nonzero and still print a JSON
        -- body with an Error field, so the output is captured either way
        -- and the JSON is read alongside the exit status.
        -- The success signal is a numeric exit-status trailer printed
        -- unconditionally as the very last line (same as the install step
        -- below): a fixed success word could be forged by output text,
        -- the final trailer line cannot.
        local dl = cmd.exec(
            "st=0 && { " .. goenv .. " GOFLAGS='-mod=mod -modcacherw' " ..
            q(go_bin) .. " mod download -json " .. q(module_root .. "@" .. tag) ..
            " 2>&1 || st=$?; } && echo \"GOMOD_EXIT=$st\"")
        local finished = dl:match("GOMOD_EXIT=(%d+)%s*$") == "0"
        local body = strings.trim_space((dl:gsub("GOMOD_EXIT=%d+%s*$", "")))
        -- "go mod download" can print diagnostics (a go.mod warning, a
        -- "go: downloading ..." progress line) to stderr before the JSON
        -- object.
        -- 2>&1 merges that ahead of it, so the first balanced {...} is
        -- pulled out rather than trusting the whole capture to be pure
        -- JSON — otherwise a harmless diagnostic line would turn into a
        -- false "could not verify" abort on a perfectly good module.
        local json_body = body:match("%b{}")
        local decoded_ok, decoded = pcall(json.decode, json_body or body)
        -- a failed download usually still prints a JSON body whose Error
        -- field says why; surface that specific reason first
        if decoded_ok and type(decoded) == "table"
            and decoded.Error ~= nil and decoded.Error ~= "" then
            error("go proxy rejected " .. module_root .. "@" .. tag .. ": " .. decoded.Error)
        end
        if not finished or not decoded_ok or type(decoded) ~= "table" then
            local detail = strings.split(body, "\n")[1] or ""
            error("could not verify " .. ctx.tool .. " " .. ctx.version ..
                  " against the go proxy: " .. detail)
        end
        if decoded.Sum ~= vrec.h1 then
            error("module checksum mismatch for " .. ctx.tool .. " " .. ctx.version ..
                  " (expected " .. vrec.h1 .. ", got " .. tostring(decoded.Sum) .. ")")
        end
    end

    -- go install names the binary after the module path's last element
    -- (the catalog validator enforces name == last element of module), and
    -- writes it into GOBIN, which must exist first.
    local bin_dir = file.join_path(ctx.install_path, "bin")
    -- The success signal is a numeric exit-status trailer printed
    -- unconditionally as the very last line, never a fixed word:
    -- compile diagnostics are attacker-influenced text (a source file
    -- failing with "undefined: SOME_MARKER" ends the output with exactly
    -- that marker), and a forged trailer earlier in the output loses to
    -- the real one because only the final line is read.
    local out = cmd.exec(
        "mkdir -p " .. q(bin_dir) .. " && st=0 && { " ..
        goenv .. " GOFLAGS=-modcacherw GOBIN=" .. q(bin_dir) ..
        " " .. q(go_bin) .. " install " .. q(tool.module .. "@" .. tag) ..
        " 2>&1 || st=$?; } && echo \"GOINSTALL_EXIT=$st\"")
    local status = out:match("GOINSTALL_EXIT=(%d+)%s*$")
    if status ~= "0" then
        local detail = strings.split(strings.trim_space(out), "\n")[1] or ""
        error("go install failed for " .. ctx.tool .. " " .. ctx.version ..
              (detail ~= "" and (": " .. detail) or ""))
    end
    -- belt and braces: a zero exit without the expected binary is still
    -- a failed install (the validator guarantees the binary name equals
    -- the tool name)
    if not file.exists(file.join_path(bin_dir, ctx.tool)) then
        error("go install reported success but produced no " .. ctx.tool ..
              " binary in " .. bin_dir)
    end

    return {}
end

function PLUGIN:BackendInstall(ctx)
    local common = require("lib/common")
    local file = require("file")
    local cmd = require("cmd")
    local archiver = require("archiver")
    local strings = require("strings")
    local json = require("json")

    local tool = common.load_tool(ctx.tool)
    local versions = common.load_versions(ctx.tool)

    -- 1. version must be approved (shared by every tool type)
    local vrec = common.find_version(versions, ctx.version)
    if vrec == nil then
        error(ctx.tool .. " " .. ctx.version .. " is not an approved version")
    end

    if tool.type == "go" then
        return install_go_tool(ctx, tool, vrec, common, cmd, strings, json)
    end

    local platform = common.platform()

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
    -- `|| true` keeps the shell exit at zero: cmd.exec raises on a nonzero
    -- exit with a generic message, and the specific error below must win.
    -- On failure the captured output is curl's own error (stderr, via 2>&1)
    -- and the CURL_OK marker is absent.
    local dl = cmd.exec("curl -fsSL --max-redirs 0 -n --retry 2 -o " .. q(dest) .. " " .. q(url) ..
                        " 2>&1 && echo CURL_OK || true")
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
