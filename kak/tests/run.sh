#!/bin/sh
# Headless checks: loads this config in a real Kakoune (-ui dummy) with fake
# external tools (fzf, wl-copy, tmux, verilator ...) and checks what it does.
# Needs: kak, git, python3 (3.11+ for the TOML check), a C compiler. With
# kak-lsp on PATH the LSP wiring is tested too; with cmake + ninja, the CMake path.
#
#   tests/run.sh

here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'pkill -x kak-lsp 2>/dev/null; rm -rf "$tmp"' EXIT
export HOME=$tmp/home XDG_CACHE_HOME=$tmp/cache KAKOUNE_CONFIG_DIR=$here
export OUT=$tmp/out CLIP=$tmp/clip WAYLAND_DISPLAY=fake
unset TMUX TMUX_PANE IN_NIX_SHELL
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$OUT" "$tmp/bin" "$tmp/work"
cd "$tmp/work" || exit 1

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL  %s\n      %s\n' "$1" "$2"; }
expect() { # name file expected-substring
    if grep -qF -- "$3" "$OUT/$2" 2>/dev/null; then ok "$1"; else bad "$1" "wanted '$3' in $2, got: $(head -c 300 "$OUT/$2" 2>/dev/null)"; fi
}
expect_not() {
    if grep -qF -- "$3" "$OUT/$2" 2>/dev/null; then bad "$1" "did not want '$3' in $2"; else ok "$1"; fi
}

# ── fake tools ──────────────────────────────────────────────────────────
cat >"$tmp/bin/fzf" <<'EOF'
#!/bin/sh
case " $* " in *" --disabled "*) echo "a.c:1:5:int main" ;; *) head -n1 ;; esac
EOF
cat >"$tmp/bin/wl-copy" <<'EOF'
#!/bin/sh
cat >"$CLIP"
EOF
cat >"$tmp/bin/wl-paste" <<'EOF'
#!/bin/sh
cat "$CLIP"
EOF
cat >"$tmp/bin/tmux" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >>"$OUT/tmux-args"
EOF
cat >"$tmp/bin/verilator" <<'EOF'
#!/bin/sh
eval "last=\${$#}"
echo "%Warning-WIDTH: $last:3:5: Operator ASSIGNW expects 4 bits on the Assign RHS, but Assign RHS's CONST '1' generates 1 bits."
echo "                    : ... note: In instance 'top'"
echo "%Error: $last:9:1: syntax error, unexpected endmodule"
EOF
cat >"$tmp/bin/clang-format" <<'EOF'
#!/bin/sh
tr a-z A-Z
EOF
chmod +x "$tmp/bin/"*
PATH=$tmp/bin:$PATH
export PATH

# Run kak headless: kakrun 'commands' [file]. `report KEY VALUE` writes $OUT/KEY.
kakrun() {
    timeout 30 kak -ui dummy -e "
        define-command report -params 2 %{ nop %sh{ printf '%s' \"\$2\" > \"\$OUT/\$1\" } }
        define-command keys -params 1 %{ execute-keys -with-maps -with-hooks -save-regs '' %arg{1} }
        try %{ $1 } catch %{ echo -debug \"TEST ERROR: %val{error}\" }
        buffer *debug*; write -force \"$OUT/debug\"
        quit!" ${2:-} </dev/null >"$OUT/stdout" 2>&1
}

printf 'int main(void) { return 0; }\n' >a.c
printf 'foo bar foo baz foo\n' >mc.txt

# ── 1. loads cleanly ────────────────────────────────────────────────────
kakrun 'nop' a.c
expect_not "config loads without errors" debug "rror"
expect_not "no warnings about missing modules" debug "no language module"

# ── 2. keys ─────────────────────────────────────────────────────────────
kakrun "
    map global user z ': report leader yes<ret>'
    keys '<space>z'
    keys 'gg<c-n><c-n>'; report cursors %val{selection_count}
    keys '<space>M'; report all %val{selection_count}
" mc.txt
expect "<space> opens the user mode" leader "yes"
expect "<c-n> adds a cursor per press" cursors "3"
expect "<space>M puts a cursor on every match" all "3"

# ── 3. clipboard ────────────────────────────────────────────────────────
printf 'PASTED' >"$CLIP"
kakrun "keys '<space>p'; write -force $tmp/pasted.txt" mc.txt
grep -q "PASTED" "$tmp/pasted.txt" && ok "<space>p pastes the system clipboard" || bad "<space>p pastes the system clipboard" "$(cat "$tmp/pasted.txt")"
printf 'PASTED' >"$CLIP"
kakrun "keys 'xy'" mc.txt
sleep 0.5
[ "$(head -c 7 "$CLIP")" = "foo bar" ] && ok "yank reaches the system clipboard" || bad "yank reaches the system clipboard" "CLIP: $(cat "$CLIP")"

# ── 4. format on save and its guards ────────────────────────────────────
printf 'hello\n' >f.txt
kakrun "set-option buffer formatcmd 'tr a-z A-Z'; set-option buffer format_on_save true; write" f.txt
grep -q HELLO f.txt && ok "format on save runs formatcmd" || bad "format on save runs formatcmd" "$(cat f.txt)"
printf 'hello\n' >f.txt
kakrun "set-option buffer formatcmd 'tr a-z A-Z'; set-option buffer format_on_save true; set-option buffer format_guard 'exit 1'; write" f.txt
grep -q hello f.txt && ok "a failing guard skips format on save" || bad "a failing guard skips format on save" "$(cat f.txt)"
printf 'hello\n' >f.txt
kakrun "set-option buffer formatcmd 'false'; set-option buffer format_on_save true; write" f.txt
grep -q hello f.txt && ok "a failing formatter never loses the save" || bad "a failing formatter never loses the save" "$(cat f.txt)"

mkdir -p nofmt fmt
printf 'int  x;\n' >nofmt/a.c
printf 'int  x;\n' >fmt/a.c
printf 'BasedOnStyle: LLVM\n' >fmt/.clang-format
kakrun 'write' nofmt/a.c
kakrun 'write' fmt/a.c
grep -q 'int  x' nofmt/a.c && ok "C: no .clang-format, no format on save" || bad "C: no .clang-format, no format on save" "$(cat nofmt/a.c)"
grep -q 'INT  X' fmt/a.c && ok "C: .clang-format pins a style, save formats" || bad "C: .clang-format pins a style, save formats" "$(cat fmt/a.c)"

# ── 5. languages ────────────────────────────────────────────────────────
: >t.v
: >t.sv
: >t.vert
: >t.nix
: >t.md
: >t.lua
mkdir -p rs
printf '[package]\nname="x"\n' >rs/Cargo.toml
: >rs/main.rs
for f in t.v t.sv t.vert; do
    kakrun "report ft %opt{filetype}" $f
    case $f in t.v) want=verilog ;; t.sv) want=systemverilog ;; *) want=glsl ;; esac
    expect "$f is $want" ft "$want"
done

# opening each kind of file runs its highlighters and hooks without errors
printf 'module m(input wire [3:0] a, output reg b);\n  always @(posedge clk) b <= 4'"'"'b1010; // x\n  `define W 8\n  initial $display("hi");\nendmodule\n' >hl.v
printf '#version 450\nlayout(location = 0) in vec3 pos;\nuniform sampler2D tex;\nvoid main() { gl_Position = vec4(pos, 1.0); }\n' >hl.frag
printf '{ pkgs, ... }: { x = 1; }\n' >hl.nix
printf '# t\n\nsome *text*\n' >hl.md
printf 'local x = 1\n' >hl.lua
printf 'fn main() {}\n' >hl.rs
printf 'int main(void) { return 0; }\n' >hl.cpp
for f in hl.v hl.frag hl.nix hl.md hl.lua hl.rs hl.cpp; do
    kakrun "nop" $f
    if grep -qi "rror" "$OUT/debug"; then bad "$f opens without errors" "$(grep -i rror "$OUT/debug" | head -3)"; else ok "$f opens without errors"; fi
done

# every language's lsp_servers must be valid TOML, and ours (not kak-lsp's default)
if command -v kak-lsp >/dev/null 2>&1 && python3 -c 'import tomllib' 2>/dev/null; then
    for f in a.c t.v t.vert t.nix t.md t.lua rs/main.rs; do
        kakrun "report servers %opt{lsp_servers}" $f
        cp "$OUT/servers" "$tmp/servers.$(basename $f).toml"
        python3 -c "import tomllib,sys; d=tomllib.load(open(sys.argv[1],'rb')); print(','.join(d))" "$tmp/servers.$(basename $f).toml" >"$OUT/names" 2>"$OUT/tomlerr" \
            && ok "$f: lsp_servers is valid TOML ($(cat "$OUT/names"))" || bad "$f: lsp_servers is valid TOML" "$(cat "$OUT/tomlerr")"
    done
    kakrun "report servers %opt{lsp_servers}" t.nix
    expect "nix uses nil, not kak-lsp's default nixd" servers "[nil]"
    printf '{ }' >rs/flake.nix
    kakrun "report servers %opt{lsp_servers}" rs/main.rs
    expect "rust in a flake runs rust-analyzer through nix develop" servers 'command = "nix"'
else
    echo "skip  LSP checks (need kak-lsp on PATH and python 3.11+)"
fi

# verilog: lint output must become something *make* can jump from
kakrun "define-command -override make nop; verilog-lint; report cmd %opt{makecmd}; report pattern %opt{make_error_pattern}" t.v
sh -c "$(cat "$OUT/cmd")" >"$OUT/lint" 2>&1
expect "verilator warnings become file:line:col: Warning:" lint "t.v:3:5: Warning:"
expect "verilator errors become file:line:col: Error:" lint "t.v:9:1: Error:"
grep -E "^[^:]+:[0-9]+:([0-9]+:)? (Error|Warning):" "$OUT/lint" >/dev/null && ok "lint lines match make_error_pattern" || bad "lint lines match make_error_pattern" "$(cat "$OUT/lint")"

# C: single file, then a CMake project
kakrun "define-command -override make nop; c-do build; report cmd %opt{makecmd}" a.c
sh -c "$(cat "$OUT/cmd")" >"$OUT/cc" 2>&1 && ok "C: single-file build compiles" || bad "C: single-file build compiles" "$(cat "$OUT/cc")"
if command -v cmake >/dev/null 2>&1; then
    mkdir -p proj/src/sub
    printf 'cmake_minimum_required(VERSION 3.20)\nproject(p C)\nadd_subdirectory(src)\n' >proj/CMakeLists.txt
    printf 'add_subdirectory(sub)\n' >proj/src/CMakeLists.txt
    printf 'add_executable(hello main.c)\n' >proj/src/sub/CMakeLists.txt
    printf '#include <stdio.h>\nint main(void){puts("hi");return 0;}\n' >proj/src/sub/main.c
    kakrun "define-command -override make nop; c-do build; report cmd %opt{makecmd}" proj/src/sub/main.c
    sh -c "$(cat "$OUT/cmd")" >"$OUT/cm" 2>&1
    [ -x proj/build/src/sub/hello ] && ok "C: CMake project builds at the topmost CMakeLists.txt" || bad "C: CMake project builds at the topmost CMakeLists.txt" "$(tail -5 "$OUT/cm")"
    [ -e proj/compile_commands.json ] && ok "C: compile_commands.json linked to the root" || bad "C: compile_commands.json linked to the root" "missing"
else
    echo "skip  CMake checks (no cmake)"
fi

# ── 6. git ──────────────────────────────────────────────────────────────
mkdir -p repo && (
    cd repo || exit
    git init -q . && git config user.email t@t && git config user.name t
    printf 'one\ntwo\nthree\n' >g.txt && git add g.txt && git commit -qm init
    printf 'one\nTWO\nthree\n' >g.txt
)
kakrun "
    git-gutter show-diff
    keys 'gg'
    git next-hunk
    git apply --cached
    report staged yes
" repo/g.txt
(cd repo && git diff --cached --stat | grep -q g.txt) && ok "git: selected hunk stages" || bad "git: selected hunk stages" "$(cd repo && git diff --cached; git status --short)"

# ── 7. panes and pickers (kak-pane against a live session) ─────────────
sess=t$$
mkdir -p pickdir && cp a.c pickdir/
(cd pickdir && kak -d -s $sess >/dev/null 2>&1) &
sleep 0.5
(sleep 20 | kak -c $sess -ui dummy -e 'rename-client c1' >/dev/null 2>&1) &
sleep 0.5
kak -p $sess <<EOF
define-command -override terminal -params 1.. %{ nop %sh{ printf '%s\n' "\$@" > "$OUT/terminal-args" } }
EOF
"$here/bin/kak-pane" _pick $sess c1 "$tmp/work/pickdir" files
sleep 0.3
kak -p $sess <<EOF
evaluate-commands -client c1 %{ nop %sh{ printf '%s' "\$kak_bufname" > "$OUT/picked" } }
EOF
sleep 0.3
expect "pick files opens the choice in the client" picked "a.c"

"$here/bin/kak-pane" _pick $sess c1 "$tmp/work/pickdir" grep
sleep 0.3
kak -p $sess <<EOF
evaluate-commands -client c1 %{ nop %sh{ printf '%s:%s' "\$kak_bufname" "\$kak_cursor_column" > "$OUT/picked" } }
EOF
sleep 0.3
expect "pick grep jumps to line and column" picked "a.c:5"

"$here/bin/kak-pane" split $sess c1 "$tmp/work" make -j2
sleep 0.3
expect "no tmux: a split asks Kakoune for a terminal" terminal-args "make"
expect "no tmux: the terminal starts in the cwd" terminal-args "$tmp/work"

TMUX=fake TMUX_PANE=%3 "$here/bin/kak-pane" popup $sess c1 "$tmp/work" lazygit
expect "tmux: popup uses display-popup" tmux-args "display-popup"
expect "tmux: popup targets the client's pane" tmux-args "%3"
rm -f "$OUT/tmux-args"
TMUX=fake TMUX_PANE=%3 "$here/bin/kak-pane" side $sess c1 "$tmp/work" claude --continue
expect "tmux: side pane splits to the right" tmux-args "-h"
expect "tmux: side pane passes the command" tmux-args "'claude' '--continue'"

kak -p $sess <<EOF
quit!
EOF

# ── 8. reload ───────────────────────────────────────────────────────────
kakrun "config-reload; config-reload; report done yes" a.c
expect "config-reload twice works" done "yes"
expect_not "no errors after reloading" debug "error"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
