# Options. Mirrors the top of init.lua: relative numbers, no wrap, 4-wide indent.

set-option global tabstop 4
set-option global indentwidth 4

# Edits made elsewhere (Claude in another pane, jj, a formatter) show up on their own.
set-option global autoreload yes

# No clippy in the terminal.
set-option global ui_options terminal_assistant=none

# :grep goes through ripgrep, with columns so the jumps land on the match.
set-option global grepcmd 'rg --column --line-number --no-heading --color=never --smart-case --hidden -g !.git'

add-highlighter -override global/numbers number-lines -relative -hlcursor
add-highlighter -override global/matching show-matching
