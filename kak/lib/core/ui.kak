# Theme and statusline. catppuccin (mocha, as in nvim), transparent like
# `transparent_background = true` there.

colorscheme catppuccin_mocha

evaluate-commands %sh{
    if [ "$kak_opt_transparent" = true ]; then
        echo "set-face global Default 'rgb:cdd6f4,default'"
        echo "set-face global BufferPadding 'rgb:6c7086,default'"
        echo "set-face global StatusLine 'rgb:cdd6f4,default'"
    fi
}

# lib/core/lsp.kak puts the language server's state in front of this.
set-option global modelinefmt '{{context_info}} {{mode_info}} %val{bufname} %val{cursor_line}:%val{cursor_char_column}'
