local M = {}

local function mkdir(dir, callback)
    local mode = tonumber("755", 8)
    vim.uv.fs_stat(dir, function(err, stat)
        if stat and stat.type == 'directory' then
            callback()
        end
        vim.uv.fs_mkdir(dir, mode, function(err)
            if err then return end
            callback()
        end)
    end)
end

local function gen_cargo(root_dir, deps)
    local content = [[
        [package]
        name = "nvim-router"
        version = "0.1.0"
        edition = "2024"

        [dependencies]
        nvim-router = { git = "https://github.com/naughie/nvim-router.rs.git", branch = "main", features = ["tokio"] }
        tokio = { version = "1", features = ["macros", "rt-multi-thread", "sync"] }
    ]]

    for i, dep in ipairs(deps) do
        local dep_line = string.format('dep%d = { package = "%s", path = "%s" }', i, dep.package, dep.path)
        content = content .. dep_line .. "\n"
    end

    local cargo_path = root_dir .. "/Cargo.toml"
    local file = io.open(cargo_path, "w")
    if not file then return end

    local write_ok = file:write(content)
    if not write_ok  then return end

    local close_ok = file:close()
    if not close_ok then return end

    return true
end

local function gen_main(root_dir, deps)
    local body = [[
        use std::error::Error;

        use tokio::fs::File as TokioFile;

        use nvim_router::NeovimHandler;
        use nvim_router::Router;
        use nvim_router::nvim_rs::{compat::tokio::Compat, create::tokio as create};

        type NvimWtr = Compat<TokioFile>;
    ]]

    for i, dep in ipairs(deps) do
        local dep_mod = string.format([[
            mod dep%d {
                pub use dep%d::NeovimHandler as H;
                #[derive(Clone)]
                pub struct N;
                impl nvim_router::Namespace for N {
                    const NS: &str = "%s";
                }
            }
        ]], i, i, dep.ns)
        body = body .. dep_mod
    end

    local deps_types = ""
    for i in ipairs(deps) do
        deps_types = deps_types .. string.format("(dep%d::N, dep%d::H),", i, i)
    end

    local deps_vals = ""
    for i in ipairs(deps) do
        deps_vals = deps_vals .. string.format("(dep%d::N, <dep%d::H as NeovimHandler<NvimWtr>>::new()),", i, i)
    end

    body = body .. [[
    ]]

    body = body .. string.format([[
        #[tokio::main]
        async fn main() -> Result<(), Box<dyn Error>> {
            let handler = Router::<NvimWtr, (%s)>::new((%s));
            let (nvim, io_handler) = create::new_parent(handler).await?;

            // Any error should probably be logged, as stderr is not visible to users.
            match io_handler.await {
                Err(joinerr) => eprintln!("Error joining IO loop: '{joinerr}'"),
                Ok(Err(err)) => {
                    if !err.is_reader_error() {
                        // One last try, since there wasn't an error with writing to the
                        // stream
                        nvim.err_writeln(&format!("Error: '{err}'"))
                            .await
                            .unwrap_or_else(|e| {
                                // We could inspect this error to see what was happening, and
                                // maybe retry, but at this point it's probably best
                                // to assume the worst and print a friendly and
                                // supportive message to our users
                                eprintln!("Well, dang... '{e}'");
                            });
                    }

                    if !err.is_channel_closed() {
                        // Closed channel usually means neovim quit itself, or this plugin was
                        // told to quit by closing the channel, so it's not always an error
                        // condition.
                        eprintln!("Error: '{err}'");

                        let mut source = err.source();

                        while let Some(e) = source {
                            eprintln!("Caused by: '{e}'");
                            source = e.source();
                        }
                    }
                }
                Ok(Ok(())) => {}
            }

            Ok(())
        }
    ]], deps_types, deps_vals)

    local main_path = root_dir .. "/src/main.rs"
    local file = io.open(main_path, "w")
    if not file then return end

    local write_ok = file:write(body)
    if not write_ok  then return end

    local close_ok = file:close()
    if not close_ok then return end

    return true
end

local function create_bin_project(root_dir, deps, callback)
    local mode = tonumber("755", 8)
    mkdir(root_dir, function()
        if not gen_cargo(root_dir, deps) then return end

        mkdir(root_dir .. "/src", function()
            if not gen_main(root_dir, deps) then return end

            callback()
        end)
    end)
end

local function create_and_build(root_dir, deps, callback)
    create_bin_project(root_dir, deps, function()
        vim.system({ "cargo", "build", "--release" }, { cwd = root_dir }, callback)
    end)
end

local opts = { deps = {} }
local configured_deps = {}

local main_dir = "/nvim-router-bin"

local job_state = { id = nil }

local function plugin_cmd()
    return opts.plugin_dir .. main_dir .. "/target/release/nvim-router"
end

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

function M.spawn()
    if job_state.id or not opts.plugin_dir then return end
    local cmd = plugin_cmd()

    if vim.fn.executable(cmd) == 0 then return end

    local id = vim.fn.jobstart({ cmd }, { rpc = true })
    if id ~= 0 and id ~= 1 then
        job_state.id = id

        return true
    end
end

function M.build_if_all_registered()
    if not opts.plugin_dir then return end

    for _, val in pairs(configured_deps) do
        if not val then return end
    end

    local root_dir = opts.plugin_dir .. main_dir
    create_and_build(root_dir, opts.deps, function()
        vim.schedule(M.spawn)
    end)
end

function M.register(dep)
    table.insert(opts.deps, dep)
    configured_deps[dep.ns] = true

    M.build_if_all_registered()
end

function M.setup(init_opts)
    opts.plugin_dir = init_opts.plugin_dir

    for _, ns in ipairs(init_opts.ns) do
        if not configured_deps[ns] then 
            configured_deps[ns] = false
        end
    end

    M.build_if_all_registered()
end

return M
