# Nix: `nil` for diagnostics, completion, go-to-definition and rename (what
# lang/nix.lua uses); nixfmt (RFC style) formats on save with two-space indents.

hook -group config global WinSetOption filetype=nix %{
    try lsp-setup-window
}

hook -group config global BufSetOption filetype=nix %{
    set-option buffer tabstop 2
    set-option buffer indentwidth 2
    set-option buffer lsp_servers %{
        [nil]
        root_globs = ["flake.nix", "shell.nix", ".git", ".hg"]
        settings_section = "nil"
        [nil.settings.nil]
        formatting.command = ["nixfmt"]
    }
    set-option buffer formatcmd 'nixfmt'
    set-option buffer format_on_save true
}
