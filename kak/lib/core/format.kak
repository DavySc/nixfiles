# Formatting. conform.nvim formats on save, a language can veto that per
# buffer, and `:Format` always works. Here:
#   formatcmd        the formatter (stdin to stdout), set per language
#   format_on_save   a language opts in
#   format_guard     shell test; saves only format when it succeeds (empty: always)
#   `format`         Kakoune's own command, runs formatcmd; <space>cf

declare-option -docstring 'format when the buffer is written' bool format_on_save false
declare-option -docstring 'shell test run before formatting on save; empty means always' str format_guard ''
declare-option -docstring 'format on save through the language server instead of formatcmd' bool format_with_lsp false

hook -group config global BufWritePre .* %{
    evaluate-commands %sh{
        [ "$kak_opt_format_on_save" = true ] || exit 0
        export kak_buffile # named here so Kakoune passes it on to the guard
        if [ -n "$kak_opt_format_guard" ]; then
            sh -c "$kak_opt_format_guard" || exit 0
        fi
        if [ "$kak_opt_format_with_lsp" = true ]; then
            echo "try lsp-formatting-sync catch %{ echo -debug 'format: lsp-formatting-sync failed' }"
        else
            echo "try format-buffer catch %{ echo -debug 'format: formatter failed' }"
        fi
    }
}

# True when a .clang-format governs the buffer. clang-format always has an
# opinion: with none in the tree it rewrites a whole file to LLVM style, so C,
# C++ and GLSL only format on save when the project pins a style.
declare-option -hidden str clang_format_guard %{
    d=$(dirname "$kak_buffile")
    while :; do
        [ -e "$d/.clang-format" ] || [ -e "$d/_clang-format" ] && exit 0
        [ "$d" = / ] || [ "$d" = . ] && exit 1
        d=$(dirname "$d")
    done
}
