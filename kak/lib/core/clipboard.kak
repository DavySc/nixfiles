# Clipboard. nvim has `clipboard = unnamedplus`: every yank and delete lands in
# the system clipboard. Here the same through bin/kak-clip, one way. Reading
# the system clipboard is explicit: <space>p / <space>P.

hook -group config global RegisterModified '"' %{
    nop %sh{ printf %s "$kak_main_reg_dquote" | "$kak_opt_config_dir/bin/kak-clip" copy >/dev/null 2>&1 & }
}

map global user p "<a-!>%opt{config_dir}/bin/kak-clip paste<ret>" -docstring 'paste system clipboard after'
map global user P "!%opt{config_dir}/bin/kak-clip paste<ret>" -docstring 'paste system clipboard before'
