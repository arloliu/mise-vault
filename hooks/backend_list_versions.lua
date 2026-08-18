--- mise ls-remote <tool>: list company-approved versions from the bundled catalog.
--- Must never contact Nexus, GitHub, or any network service:
--- the locally installed catalog alone decides what is visible.
--- The catalog array is already in ascending approval order (CI-enforced);
--- returning it verbatim avoids semver assumptions about tool version schemes.
function PLUGIN:BackendListVersions(ctx)
    local common = require("lib/common")

    local records = common.load_versions(ctx.tool)
    local versions = {}
    for _, rec in ipairs(records) do
        table.insert(versions, rec.version)
    end
    return { versions = versions }
end
