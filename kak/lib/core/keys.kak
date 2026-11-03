# Keys. <space> is the leader, as in nvim: Kakoune opens its `user` mode on
# <space> (since 2022.10; `,` keeps only the main selection), and the menu
# appears after a moment, like which-key.

# Groups, named like the which-key groups in nvim. A mode is declared once;
# on a reload that is an error we can ignore.
evaluate-commands %sh{
    for mode in find git hunk code rename diag make ai ui; do
        echo "try %{ declare-user-mode $mode }"
    done
}

map global user f ': enter-user-mode find<ret>' -docstring 'find…'
map global user g ': enter-user-mode git<ret>' -docstring 'git…'
map global user h ': enter-user-mode hunk<ret>' -docstring 'hunks…'
map global user c ': enter-user-mode code<ret>' -docstring 'code…'
map global user r ': enter-user-mode rename<ret>' -docstring 'rename…'
map global user x ': enter-user-mode diag<ret>' -docstring 'diagnostics…'
map global user m ': enter-user-mode make<ret>' -docstring 'make / run…'
map global user a ': enter-user-mode ai<ret>' -docstring 'ai (Claude)…'
map global user u ': enter-user-mode ui<ret>' -docstring 'ui…'

# Same top-level keys as nvim where Kakoune has the thing.
map global user , ': pick buffers<ret>' -docstring 'buffers'
map global user e ': pick explore<ret>' -docstring 'file explorer'
map global user R ': config-reload<ret>' -docstring 'reload config'

# Find
map global find f ': pick files<ret>' -docstring 'files'
map global find g ': pick grep<ret>' -docstring 'grep'
map global find t ': pane popup %sh{echo ${SHELL:-sh}}<ret>' -docstring 'terminal'

# VS Code's Ctrl-D: a cursor on the word, then one on its next match each press.
# (Kakoune's own way is `*` then `n` / `N`, or `s` on a selection.)
map global normal <c-n> '<a-i>w*N' -docstring 'add cursor on next match of word'
# A cursor on every match of the word.
map global user M '<a-i>w*%s<c-r>/<ret>' -docstring 'cursor on every match of word'

# Insert mode: Tab walks the completion menu when it is open (and only then),
# so Tab keeps indenting otherwise. Snippet placeholders hook in from lsp.kak.
hook -group config global InsertCompletionShow .* %{
    try %{
        # fails (and so skips the maps) when the cursor follows whitespace
        execute-keys -draft 'h<a-K>\h<ret>'
        map window insert <tab> <c-n>
        map window insert <s-tab> <c-p>
        hook -once -always window InsertCompletionHide .* %{
            unmap window insert <tab> <c-n>
            unmap window insert <s-tab> <c-p>
        }
    }
}

# UI toggles
map global ui w ': toggle-wrap<ret>' -docstring 'soft wrap'

define-command -override toggle-wrap -docstring 'toggle soft wrap in this window' %{
    try %{
        add-highlighter window/wrap wrap -word -indent
        echo 'wrap on'
    } catch %{
        remove-highlighter window/wrap
        echo 'wrap off'
    }
}
