# Lua (nvim config, plugins). lua-language-server and stylua.

hook -group config global WinSetOption filetype=lua %{
    try lsp-setup-window
}

hook -group config global BufSetOption filetype=lua %{
    set-option buffer lsp_servers %{
        [lua-language-server]
        root_globs = [".git", ".hg"]
        single_instance = false
        settings_section = "Lua"
        [lua-language-server.settings.Lua]
        runtime.version = "LuaJIT"
        diagnostics.globals = ["vim", "Snacks"]
        telemetry.enable = false
    }
    set-option buffer formatcmd "stylua --stdin-filepath '%val{buffile}' -"
    set-option buffer format_on_save true
}
