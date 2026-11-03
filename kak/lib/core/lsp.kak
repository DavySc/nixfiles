# LSP through kakoune-lsp (`kak-lsp`). Servers are listed per language in
# lib/lang/*.kak (the `lsp_servers` option); this wires the client, the keys
# and the diagnostics display. A language turns the client on for its
# filetypes with `lsp-enable-window`.

# kak-lsp's own script defines its commands without -override, so a reload
# must not run it twice (lsp_cmd exists once it has been).
evaluate-commands %sh{
    if [ -n "$kak_opt_lsp_cmd" ]; then
        exit 0
    elif command -v kak-lsp >/dev/null 2>&1; then
        kak-lsp
    else
        echo "echo -debug 'my-kak: kak-lsp is not on PATH, LSP is off'"
    fi
}

# Server state first in the statusline (busy, code actions available ...).
set-option global modelinefmt '%opt{lsp_modeline} {{context_info}} {{mode_info}} %val{bufname} %val{cursor_line}:%val{cursor_char_column}'

# Diagnostics: underlines and gutter flags come with lsp-enable-window; this
# adds the message at the end of the line, like virtual_text in nvim. Each
# language calls this for its filetypes.
define-command -override lsp-setup-window -docstring 'LSP on for this window, with diagnostics at the end of the line' %{
    lsp-enable-window
    lsp-inlay-diagnostics-enable window
}

# Goto, as in nvim: gd definition, gD declaration, gr references, gI implementation.
map global goto d '<esc>: lsp-definition<ret>' -docstring 'definition'
map global goto D '<esc>: lsp-declaration<ret>' -docstring 'declaration'
map global goto r '<esc>: lsp-references<ret>' -docstring 'references'
map global goto I '<esc>: lsp-implementation<ret>' -docstring 'implementation'
map global goto y '<esc>: lsp-type-definition<ret>' -docstring 'type definition'

# K stays Kakoune's "extend up"; hover is on the leader.
map global user k ': lsp-hover<ret>' -docstring 'hover'
map global user l ': enter-user-mode lsp<ret>' -docstring 'lsp…'

map global code a ': lsp-code-actions<ret>' -docstring 'code action'
map global code f ': format<ret>' -docstring 'format'
map global code s ': lsp-goto-document-symbol<ret>' -docstring 'symbols (file)'
map global code S ': lsp-workspace-symbol-incr<ret>' -docstring 'symbols (workspace)'
map global rename n ': lsp-rename-prompt<ret>' -docstring 'rename symbol'

map global diag x ': lsp-diagnostics<ret>' -docstring 'diagnostics (project)'
map global diag n ': lsp-find-error<ret>' -docstring 'next error'
map global diag p ': lsp-find-error --previous<ret>' -docstring 'previous error'

# Insert: signature help on <c-k>; Tab jumps to the next snippet placeholder.
map global insert <c-k> '<a-;>: lsp-signature-help<ret>' -docstring 'signature help'
map global insert <tab> '<a-;>: try lsp-snippets-select-next-placeholders catch %{ execute-keys -with-hooks <lt>tab> }<ret>' -docstring 'next snippet placeholder'

# Text objects from the syntax tree: <a-i>f function, <a-i>t type, <a-i>d diagnostic.
map global object f '<a-semicolon>lsp-object Function Method<ret>' -docstring 'function or method'
map global object t '<a-semicolon>lsp-object Class Interface Module Namespace Struct<ret>' -docstring 'class / module / struct'
map global object d '<a-semicolon>lsp-diagnostic-object error warning<ret>' -docstring 'errors and warnings'

# Inlay hints, off until asked (<space>uh).
declare-option -hidden bool inlay_hints_on false
define-command -override toggle-inlay-hints -docstring 'toggle LSP inlay hints in this window' %{
    evaluate-commands %sh{
        if [ "$kak_opt_inlay_hints_on" = true ]; then
            echo 'lsp-inlay-hints-disable window; set-option window inlay_hints_on false'
        else
            echo 'lsp-inlay-hints-enable window; set-option window inlay_hints_on true'
        fi
    }
}
map global ui h ': toggle-inlay-hints<ret>' -docstring 'inlay hints'
