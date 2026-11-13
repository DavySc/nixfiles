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
         kitty-sqldiff kitty-cat kitty-dbbliss kitty-vs kitty-ocaml kitty-souffle kitty-org-tools kitty-perf; do
    printf '== %s\n' "$t"
    "$emacs" --batch -q -L "$here/lisp" -L "$here/lisp/lang" \
        -l "$here/test/$t-test.el" -f ert-run-tests-batch-and-exit || status=1
done
exit $status
