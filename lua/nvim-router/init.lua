local M = {}

local fs_struct = require("nvim-router.fs_struct")
local gen = require("nvim-router.gen")

local job_state = { id = nil }

local function create_bin_project(plugin_dir, deps, callback)
    gen.root_dir(plugin_dir, function()
        if not gen.cargo_toml(plugin_dir, deps) then return end

        gen.src_dir(plugin_dir, function()
            if not gen.main_rs(plugin_dir, deps) then return end

            callback()
        end)
    end)
end

local function executable(plugin_dir)
    local cmd = fs_struct.binary(plugin_dir)
    return vim.fn.executable(cmd) == 1
end

local function spawn(plugin_dir)
    if job_state.id then return end
    if not executable(plugin_dir) then return end

    local cmd = fs_struct.binary(plugin_dir)
    local id = vim.fn.jobstart({ cmd }, { rpc = true })
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
    local new_deps = gen.last_deps.content(deps)

    if not force then
        local last_deps = gen.last_deps.read(plugin_dir)

        if last_deps == new_deps and executable(plugin_dir) then
            spawn(plugin_dir)
            return
        end
    end

    kill()
    create_bin_project(plugin_dir, deps, function()
        vim.system({ "cargo", "build", "--release" }, { cwd = fs_struct.root_dir(plugin_dir) }, function(out)
            if out.code == 0 then
                gen.last_deps.write(plugin_dir, new_deps)
                vim.schedule(function()
                    spawn(plugin_dir)
                end)
            end
        end)
    end)
end

local opts = { deps = {} }
local configured_deps = {}

M.rpc = {
    notify = function(ns, name, ...)
        local jobid = job_state.id
        if not jobid then return end

        vim.rpcnotify(jobid, ns .. "::" .. name, ...)
    end,

    request = function(ns, name, ...)
        local jobid = job_state.id
        if not jobid then return end

        return vim.rpcrequest(jobid, ns .. "::" .. name, ...)
    end,
}

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
