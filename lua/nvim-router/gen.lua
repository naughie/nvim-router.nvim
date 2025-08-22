local fs_struct = require("nvim-router.fs_struct")

local file_content = {
    cargo_toml = function(deps)
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

        return content
    end,

    main_rs = function(deps)
        local content = [[
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
                    pub use dep%d::%s as H;
                    #[derive(Clone)]
                    pub struct N;
                    impl nvim_router::Namespace for N {
                        const NS: &str = "%s";
                    }
                }
            ]], i, i, dep.handler, dep.ns)
            content = content .. dep_mod
        end

        local deps_types = ""
        for i in ipairs(deps) do
            deps_types = deps_types .. string.format("(dep%d::N, dep%d::H),", i, i)
        end

        local deps_vals = ""
        for i in ipairs(deps) do
            deps_vals = deps_vals .. string.format("(dep%d::N, <dep%d::H as NeovimHandler<NvimWtr>>::new()),", i, i)
        end

        content = content .. string.format([[
            #[tokio::main]
            async fn main() -> Result<(), Box<dyn Error>> {
                let handler = Router::<NvimWtr, (%s)>::new((%s));
                let (nvim, io_handler) = create::new_parent(handler).await?;

                match io_handler.await {
                    Err(joinerr) => eprintln!("Error joining IO loop: '{joinerr}'"),
                    Ok(Err(err)) => {
                        if !err.is_reader_error() {
                            nvim.err_writeln(&format!("Error: '{err}'"))
                                .await
                                .unwrap_or_else(|e| {
                                    eprintln!("Well, dang... '{e}'");
                                });
                        }

                        if !err.is_channel_closed() {
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

        return content
    end,

    last_deps = function(deps)
        local content = ""
        for _, dep in ipairs(deps) do
            local dep_obj = string.format([[
                { "package": "%s", "path": "%s", "handler": "%s", "ns": "%s" }
            ]], dep.package, dep.path, dep.handler, dep.ns)
            content = content .. dep_obj
        end
        return content
    end,
}

local mkdir_mode = tonumber("755", 8)
local function mkdir(dir, callback)
    vim.uv.fs_stat(dir, function(err, stat)
        if stat and stat.type == 'directory' then
            callback()
        end
        vim.uv.fs_mkdir(dir, mkdir_mode, function(err)
            if err then return end
            callback()
        end)
    end)
end

local function write_to_file(path, content)
    local file = io.open(path, "w")
    if not file then return end

    local write_ok = file:write(content)
    if not write_ok  then return end

    local close_ok = file:close()
    if not close_ok then return end

    return true
end

local function read_from_file(path)
    local file = io.open(path, "r")
    if not file then return end

    local content = file:read("*a")

    local close_ok = file:close()
    if not close_ok then return end

    return content
end

return {
    root_dir = function(plugin_dir, callback)
        mkdir(fs_struct.root_dir(plugin_dir), callback)
    end,

    src_dir = function(plugin_dir, callback)
        mkdir(fs_struct.src_dir(plugin_dir), callback)
    end,

    cargo_toml = function(plugin_dir, deps)
        local content = file_content.cargo_toml(deps)
        return write_to_file(fs_struct.cargo_toml(plugin_dir), content)
    end,

    main_rs = function(plugin_dir, deps)
        local content = file_content.main_rs(deps)
        return write_to_file(fs_struct.main_rs(plugin_dir), content)
    end,

    last_deps = {
        content = file_content.last_deps,

        write = function(plugin_dir, content)
            return write_to_file(fs_struct.last_deps(plugin_dir), content)
        end,

        read = function(plugin_dir)
            return read_from_file(fs_struct.last_deps(plugin_dir))
        end,
    },
}
