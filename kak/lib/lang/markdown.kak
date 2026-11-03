# Markdown: marksman for link / heading completion, references and diagnostics;
# soft wrap on word boundaries, wrapped lines indented like their first line;
# prettier formats, but only on request (<space>cf), never on save: other
# people's READMEs keep their wrapping. No in-buffer rendering (render-markdown
# has no Kakoune counterpart), Kakoune's own highlighting is what you get.

hook -group config global WinSetOption filetype=markdown %{
    add-highlighter window/wrap wrap -word -indent
    hook -once -always window WinSetOption filetype=.* %{ remove-highlighter window/wrap }
    try lsp-setup-window
}

hook -group config global BufSetOption filetype=markdown %{
    set-option buffer lsp_servers %{
        [marksman]
        root_globs = [".marksman.toml", ".git"]
        args = ["server"]
    }
    set-option buffer formatcmd "prettier --stdin-filepath '%val{buffile}'"
    set-option buffer format_on_save false
}
