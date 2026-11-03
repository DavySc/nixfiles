# Panes and pickers. Kakoune has no terminal, popup or picker of its own: it
# leans on tmux (or the windowing module of whatever you run: zellij, kitty,
# sway, Hyprland ...) and on fzf. bin/kak-pane does the work; this is the glue.
#
# pane <popup|split|side|pick> <command> [args]
#   popup  tmux popup (lazygit, a shell)
#   split  pane below, held after the command ends (build / run)
#   side   pane on the right (Claude)
#   pick   fzf picker: files, grep [query], buffers, branches, explore

define-command -override pane -params 2.. -docstring 'pane <popup|split|side|pick> <command> [args]: run in a tmux popup / pane, or a new terminal' %{
    nop %sh{
        TMUX=${kak_client_env_TMUX:-$TMUX}
        TMUX_PANE=${kak_client_env_TMUX_PANE:-$TMUX_PANE}
        export TMUX TMUX_PANE
        how=$1
        shift
        "$kak_opt_config_dir/bin/kak-pane" "$how" "$kak_session" "$kak_client" "$PWD" "$@" \
            >/dev/null 2>&1 </dev/null &
    }
}

define-command -override pick -params 1.. -docstring 'pick <files|grep|buffers|branches|explore> [query]' %{
    evaluate-commands %sh{
        if [ "$1" = buffers ]; then
            # The picker runs elsewhere; hand it the list through a file.
            list=$(mktemp "${TMPDIR:-/tmp}"/kak-buffers.XXXXXX)
            eval set -- $kak_quoted_buflist
            printf '%s\n' "$@" >"$list"
            echo "pane pick buffers '$list'"
        else
            echo "pane pick %arg{@}"
        fi
    }
}
complete-command -menu pick shell-script-candidates %{ printf '%s\n' files grep buffers branches explore }
