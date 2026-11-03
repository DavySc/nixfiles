# Git. The gutter is Kakoune's own `git show-diff` (gitsigns' signs); staging
# works on the selected lines (`git apply`), so select a hunk first.
#   <space>hn / hN  select the next / previous hunk
#   <space>hs / hr  stage / reset the selected lines
#   <space>hu       unstage them

# The gutter only where there is a repository (otherwise git's complaint ends
# up in *debug* every time a buffer is shown).
define-command -override -hidden git-gutter -params 1 %{
    evaluate-commands %sh{
        [ -n "$kak_buffile" ] || exit 0
        if git -C "$(dirname "$kak_buffile")" rev-parse --git-dir >/dev/null 2>&1; then
            echo "try %{ git $1 }"
        fi
    }
}
hook -group config global WinDisplay .* %{ git-gutter show-diff }
hook -group config global BufWritePost .* %{ git-gutter update-diff }
hook -group config global BufReload .* %{ git-gutter update-diff }

map global git g ': pane popup lazygit<ret>' -docstring 'lazygit'
map global git s ': git status<ret>' -docstring 'status'
map global git l ': git log<ret>' -docstring 'log'
map global git L ': git log -- %val{buffile}<ret>' -docstring 'log (file)'
map global git d ': git diff<ret>' -docstring 'diff'
map global git b ': pick branches<ret>' -docstring 'branches'

map global hunk n ': git next-hunk<ret>' -docstring 'next hunk'
map global hunk N ': git prev-hunk<ret>' -docstring 'previous hunk'
map global hunk s ': git apply --cached<ret>' -docstring 'stage selected lines'
map global hunk r ': git apply --reverse<ret>' -docstring 'reset selected lines'
map global hunk u ': git apply --cached --reverse<ret>' -docstring 'unstage selected lines'
map global hunk S ': git add<ret>' -docstring 'stage buffer'
map global hunk b ': git blame-jump<ret>' -docstring 'blame line (show commit)'
map global hunk t ': git blame<ret>' -docstring 'toggle blame column'
map global hunk d ': git diff -- %val{buffile}<ret>' -docstring 'diff (file)'
