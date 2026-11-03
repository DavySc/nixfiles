# Claude Code in a pane on the right. claudecode.nvim talks to nvim over the
# IDE protocol (selection, diffs); there is no such thing for Kakoune, so this
# is just a pane. Claude reads the project's CLAUDE.md as usual. Edits it makes
# show up through `autoreload`.

define-command -override claude -params 0.. -docstring 'claude [args]: Claude Code in a side pane' %{
    pane side claude %arg{@}
}

map global ai c ': claude<ret>' -docstring 'Claude'
map global ai C ': claude --continue<ret>' -docstring 'continue last session'
