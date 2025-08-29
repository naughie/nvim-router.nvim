local M = {}

local job_state = { id = nil }

local function gen_deps_json(path, deps)
    local content = "["
    for i, dep in ipairs(deps) do
        local dep_item = string.format(
            [[{"path":"%s","handler":"%s","ns":"%s"}]],
            dep.path,
            dep.handler,
            dep.ns
        )
        if i == 1 then
            content = content .. dep_item
        else
            content = content .. "," .. dep_item
        end
    end
    content = content .. "]"

    local file = io.open(path, "w")
    if not file then return end

    local write_ok = file:write(content)
    if not write_ok  then return end

    local close_ok = file:close()
    if not close_ok then return end

    return true
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
    local executable = executable(bin_path)

    local deps_path = gen_base .. "/deps.json"
    if not gen_deps_json(deps_path, deps) then return end

    local check_changes = not (not executable or force)
    vim.system({ "cargo", "run", "--release", bin_base, tostring(check_changes) }, { cwd = gen_base }, function(out)
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
