local M = {}

local job_state = { id = nil }

local function gen_deps_json(deps)
    local escape_replacements = {
        ["\""] = "\\\"",
        ["\\"] = "\\\\",
        ["\b"] = "\\b",
        ["\f"] = "\\f",
        ["\n"] = "\\n",
        ["\r"] = "\\r",
        ["\t"] = "\\t",
    }
    local replace = function(c)
        if escape_replacements[c] then return escape_replacements[c] end
        return string.format("\\u%04x", string.byte(c))
    end

    local function escape_json_string(s)
        return string.gsub(s, "[\"\\\0-\31]", replace)
    end

    local content = "["
    for i, dep in ipairs(deps) do
        local dep_item = string.format(
            [[{"path":"%s","handler":"%s","ns":"%s"}]],
            escape_json_string(dep.path),
            escape_json_string(dep.handler),
            escape_json_string(dep.ns)
        )
        if i == 1 then
            content = content .. dep_item
        else
            content = content .. "," .. dep_item
        end
    end
    content = content .. "]"

    return content
end

local function executable(path)
    return vim.fn.executable(path) == 1
end

local function spawn(bin_path)
    if job_state.id then return end
    if not executable(bin_path) then return end

    local id = vim.fn.jobstart({ bin_path }, { rpc = true })
    if id ~= 0 and id ~= 1 then
        job_state.id = id

        return true
    end
end

local function kill()
    if not job_state.id then return end
    return vim.fn.jobstop(job_state.id)
end

local function build_and_spawn(plugin_dir, deps, force)
    kill()

    local gen_base = plugin_dir .. "/lib/gen-bin-project"
    local bin_base = plugin_dir .. "/nvim-router-bin"

    local bin_path = bin_base .. "/target/release/nvim-router"

    local deps_json = gen_deps_json(deps)

    local check_changes = not force and executable(bin_path)
    vim.system({ "cargo", "run", "--release", bin_base, deps_json, tostring(check_changes) }, { cwd = gen_base }, function(out)
        if out.code == 0 then
            vim.schedule(function() spawn(bin_path) end)
        end
    end)
end

local opts = { deps = {} }
local configured_deps = {}

local function create_rpc_interface(ns)
    return {
        notify = function(name, ...)
            local jobid = job_state.id
            if not jobid then return end

            vim.rpcnotify(jobid, ns .. "::" .. name, ...)
        end,

        request = function(name, ...)
            local jobid = job_state.id
            if not jobid then return end

            return vim.rpcrequest(jobid, ns .. "::" .. name, ...)
        end,
    }
end

function M.build_and_spawn(force)
    if not opts.plugin_dir or not opts.deps then return end
    build_and_spawn(opts.plugin_dir, opts.deps, opts.force or force)
end

function M.build_if_all_registered()
    for _, val in pairs(configured_deps) do
        if not val then return end
    end

    M.build_and_spawn()
end

function M.register(dep)
    table.insert(opts.deps, dep)
    configured_deps[dep.ns] = true

    M.build_if_all_registered()

    return create_rpc_interface(dep.ns)
end

function M.setup(init_opts)
    opts.plugin_dir = init_opts.plugin_dir
    opts.force = init_opts.force

    for _, ns in ipairs(init_opts.ns) do
        if not configured_deps[ns] then 
            configured_deps[ns] = false
        end
    end

    M.build_if_all_registered()
end

return M
