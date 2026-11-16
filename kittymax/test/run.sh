#!/bin/sh
# Run the tests inside kittymax's own Emacs, so meow, markdown-mode and
# verilog-mode are the exact versions the configuration uses:
#
#   kittymax/test/run.sh            (or: nix run .#... / any `emacs` that has the packages)
#
# -q skips init files (and so early-init.el): the tests load what they need.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
emacs=${KITTYMAX_EMACS:-kittymax}
status=0
for t in kitty-lib kitty-platform kitty-smoke kitty-keys kitty-evil kitty-splash kitty-markdown kitty-verilog \
         kitty-sqldiff kitty-cat kitty-dbbliss kitty-vs kitty-souffle kitty-org-tools kitty-lean kitty-perf; do
    printf '== %s\n' "$t"
    "$emacs" --batch -q -L "$here/lisp" -L "$here/lisp/lang" \
        -l "$here/test/$t-test.el" -f ert-run-tests-batch-and-exit || status=1
done
# The infoview's refresh, as a TLA+ model (kitty_lean.tla): TLC checks it,
# and checks that it would catch the two mistakes it is there for.
if command -v tlc >/dev/null 2>&1; then
    printf '== kitty_lean.tla\n'
    tmp=$(mktemp -d)
    tlc_run() {  # DIR: 0 when TLC finds no error
        (cd "$1" && tlc -workers auto -config kitty_lean.cfg kitty_lean.tla) >"$1/out" 2>&1
        grep -q 'No error has been found' "$1/out"
    }
    for m in model no-generation-check no-forced-refresh; do
        mkdir "$tmp/$m"
        cp "$here/test/kitty_lean.cfg" "$tmp/$m/"
        case $m in
            model) cp "$here/test/kitty_lean.tla" "$tmp/$m/" ;;
            no-generation-check)
                sed 's|IF a.g = gen /\\ a.ok|IF a.ok|' "$here/test/kitty_lean.tla" >"$tmp/$m/kitty_lean.tla" ;;
            no-forced-refresh)
                sed '/^CheckingDone ==/,/^$/s|Refresh(TRUE)|Refresh(FALSE)|' "$here/test/kitty_lean.tla" >"$tmp/$m/kitty_lean.tla" ;;
        esac
        if cmp -s "$here/test/kitty_lean.tla" "$tmp/$m/kitty_lean.tla" && [ "$m" != model ]; then
            echo "$m: the mutation no longer applies"; status=1
        elif tlc_run "$tmp/$m"; then
            [ "$m" = model ] && echo "model: passes" || { echo "$m: TLC missed it"; status=1; }
        else
            [ "$m" = model ] && { cat "$tmp/$m/out"; status=1; } || echo "$m: caught"
        fi
    done
    rm -rf "$tmp"
fi
exit $status
