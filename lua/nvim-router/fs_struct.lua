local function root_dir(plugin_dir)
    return plugin_dir .. "/nvim-router-bin"
end

return {
    root_dir = root_dir,

    cargo_toml = function(plugin_dir)
        return root_dir(plugin_dir) .. "/Cargo.toml"
    end,

    src_dir = function(plugin_dir)
        return root_dir(plugin_dir) .. "/src"
    end,

    main_rs = function(plugin_dir)
        return root_dir(plugin_dir) .. "/src/main.rs"
    end,

    last_deps = function(plugin_dir)
        return root_dir(plugin_dir) .. "/last_deps.jsonl"
    end,

    binary = function(plugin_dir)
        return root_dir(plugin_dir) .. "/target/release/nvim-router"
    end,
}
