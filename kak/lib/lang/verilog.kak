# Verilog and SystemVerilog: verible for diagnostics, formatting and navigation;
# verilator lints, iverilog + vvp simulate (neither comes from here: install
# them, or let the flake do it).
#
# <space>m  m lint (verilator, into *make*)   r run (iverilog + vvp in a pane)
#
# Kakoune has no Verilog support of its own, so this file adds the filetypes
# and a small highlighter. `.v` is Verilog, not Coq (Kakoune's guess).

hook -group config global BufCreate .*\.(v|vh)$ %{ set-option buffer filetype verilog }
hook -group config global BufCreate .*\.(sv|svh)$ %{ set-option buffer filetype systemverilog }

provide-module -override verilog %{
    add-highlighter shared/verilog regions
    add-highlighter shared/verilog/code default-region group
    add-highlighter shared/verilog/line_comment region '//' '$' fill comment
    add-highlighter shared/verilog/block_comment region '/\*' '\*/' fill comment
    add-highlighter shared/verilog/string region %{"} %{(?<!\\)(\\\\)*"} fill string

    add-highlighter shared/verilog/code/numbers regex %{\b(\d+)?'[sS]?[bBoOdDhH][0-9a-fA-FxXzZ_?]+|\b\d[\d_]*(\.\d+)?\b} 0:value
    add-highlighter shared/verilog/code/directives regex %{`\w+} 0:meta
    add-highlighter shared/verilog/code/system_tasks regex \$\w+ 0:builtin
    add-highlighter shared/verilog/code/keywords regex \b(module|endmodule|macromodule|primitive|endprimitive|interface|endinterface|package|endpackage|program|endprogram|class|endclass|function|endfunction|task|endtask|begin|end|fork|join|join_any|join_none|generate|endgenerate|genvar|if|else|case|casex|casez|endcase|default|for|foreach|while|repeat|forever|do|return|break|continue|assign|deassign|force|release|always|always_comb|always_ff|always_latch|initial|final|posedge|negedge|or|and|not|nand|nor|xor|xnor|buf|parameter|localparam|defparam|input|output|inout|import|export|modport|typedef|enum|struct|union|packed|unique|priority|automatic|static|virtual|extends|new|this|super|assert|assume|cover|property|endproperty|sequence|endsequence|disable|wait|specify|endspecify|specparam)\b 0:keyword
    add-highlighter shared/verilog/code/types regex \b(wire|reg|logic|bit|byte|shortint|int|longint|integer|time|real|realtime|shortreal|string|event|signed|unsigned|tri|tri0|tri1|wand|wor|supply0|supply1|var|const|void)\b 0:type
}

hook -group config global WinSetOption filetype=(verilog|systemverilog) %{
    require-module verilog
    add-highlighter window/verilog ref verilog
    hook -once -always window WinSetOption filetype=.* %{ remove-highlighter window/verilog }
    try lsp-setup-window
}

hook -group config global BufSetOption filetype=(verilog|systemverilog) %{
    set-option buffer comment_line '//'
    set-option buffer comment_block_begin '/*'
    set-option buffer comment_block_end '*/'

    set-option buffer lsp_servers %{
        [verible-verilog-ls]
        root_globs = [".git", ".hg"]
    }
    set-option buffer formatcmd 'verible-verilog-format -'
    set-option buffer format_on_save true

    map buffer make m ': verilog-lint<ret>' -docstring 'lint (verilator)'
    map buffer make r ': verilog-run<ret>' -docstring 'run (iverilog + vvp)'
}

define-command -override verilog-lint -docstring 'verilator --lint-only -Wall on this file; findings in *make*' %{
    evaluate-commands %sh{
        sv=; [ "$kak_opt_filetype" = systemverilog ] && sv=-sv
        # "%Warning-WIDTH: f.v:3:5: msg" -> "f.v:3:5: Warning: msg", which *make* can jump from.
        # (printf, not echo: dash's echo would turn \1 and \n into control characters)
        printf '%s\n' "set-option buffer makecmd %{verilator --lint-only -Wall $sv '$kak_buffile' 2>&1 | sed -E 's/^%(Error|Warning)[^:]*: /\\1: /;s/^(Error|Warning): ([^:]+:[0-9]+(:[0-9]+)?): /\\2: \\1: /'}"
        printf '%s\n' "set-option buffer make_error_pattern '^([^:\\n]+):(\\d+):(?:(\\d+):)? (?:Error|Warning):(\\N+)?'"
        echo make
    }
}

define-command -override verilog-run -params 0.. -docstring 'verilog-run [plusargs]: iverilog this file (a testbench, usually) and run it with vvp in a pane' %{
    evaluate-commands %sh{
        file=$kak_buffile
        if [ -z "$file" ]; then echo "fail 'verilog: the buffer is not backed by a file'"; exit; fi
        dir=$(dirname "$file")
        cache=${XDG_CACHE_HOME:-$HOME/.cache}/kak/verilog
        mkdir -p "$cache"
        out=$cache/$(basename "${file%.*}")-$(printf %s "$file" | cksum | cut -d' ' -f1).vvp
        # Modules the testbench instantiates are found next to it (-y).
        echo "pane split sh -c %{iverilog -g2012 -Wall -y '$dir' -I '$dir' -o '$out' '$file' && vvp '$out' \"\$@\"} sh %arg{@}"
    }
}
