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
# The timing of kitty-lean.el as TLA+ models: TLC checks each, and checks
# that it rejects the broken versions they are there to catch.
#   kitty_lean.tla        the infoview's refresh (generations, forced refresh, flushed edits)
#   kitty_lean_rpc.tla    Lean's RPC session, lost and found again
#   kitty_lean_start.tla  one server per project while it starts
#   kitty_lean_folds.tla  a trace's children and [apply] buttons, answered late
#   kitty_lean_diags.tla  Lean's diagnostics taken in pieces, handed on once an interval
#   kitty_lean_webview.tla VS Code's infoview in a page: answers, streams, pages gone
if command -v tlc >/dev/null 2>&1; then
    tmp=$(mktemp -d)
    # NAME MODULE EXPECT(pass|fail) [SED-ON-TLA] [SED-ON-CFG]
    tlc_case() {
        d="$tmp/$1"; mkdir "$d"
        sed "${4:-}" "$here/test/$2.tla" >"$d/$2.tla"
        sed "${5:-}" "$here/test/$2.cfg" >"$d/$2.cfg"
        if [ -n "${4:-}" ] && cmp -s "$here/test/$2.tla" "$d/$2.tla"; then
            echo "$1: the mutation no longer applies"; status=1; return
        fi
        (cd "$d" && tlc -workers auto -config "$2.cfg" "$2.tla") >"$d/out" 2>&1 || true
        if grep -q 'No error has been found' "$d/out"; then got=pass
        elif grep -qE 'is violated|were violated' "$d/out"; then got=fail
        else echo "$1: TLC did not run the model"; cat "$d/out"; status=1; return; fi
        if [ "$got" = "$3" ]; then
            [ "$3" = pass ] && echo "$1: passes" || echo "$1: caught"
        else
            [ "$3" = pass ] && cat "$d/out" || echo "$1: TLC missed it"
            status=1
        fi
    }
    printf '== TLA+ models\n'
    tlc_case refresh kitty_lean pass
    tlc_case refresh-no-generation-check kitty_lean fail 's|IF a.g = gen /\\ a.ok|IF a.ok|'
    tlc_case refresh-no-forced-refresh kitty_lean fail '/^CheckingDone ==/,/^$/s|Refresh(TRUE)|Refresh(FALSE)|'
    tlc_case refresh-no-flush kitty_lean fail '' 's|Fix = TRUE|Fix = FALSE|'
    tlc_case rpc kitty_lean_rpc pass
    tlc_case rpc-reconnect-per-call kitty_lean_rpc fail '' 's|Fix = TRUE|Fix = FALSE|'
    tlc_case start kitty_lean_start pass
    tlc_case start-first-version kitty_lean_start fail '' 's|Design = "fixed"|Design = "pr"|'
    tlc_case start-no-note kitty_lean_start fail '' 's|Design = "fixed"|Design = "nonote"|'
    tlc_case start-eglot-timeout kitty_lean_start fail '' 's|Limit = 0|Limit = 1|'
    tlc_case folds kitty_lean_folds pass
    tlc_case folds-no-render-check kitty_lean_folds fail '' 's|Bug = "none"|Bug = "norender"|'
    tlc_case folds-late-answer-kept kitty_lean_folds fail '' 's|Bug = "none"|Bug = "norelease"|'
    tlc_case folds-unrendered-refresh-kept kitty_lean_folds fail '' 's|Bug = "none"|Bug = "nodrop"|'
    tlc_case folds-button-any-text kitty_lean_folds fail '' 's|Bug = "none"|Bug = "notick"|'
    tlc_case diags kitty_lean_diags pass
    tlc_case diags-not-incremental kitty_lean_diags fail '' 's|Bug = "none"|Bug = "replace"|'
    tlc_case diags-orphaned-timer kitty_lean_diags fail '' 's|Bug = "none"|Bug = "orphan"|'
    tlc_case diags-leading-edge-only kitty_lean_diags fail '' 's|Bug = "none"|Bug = "leading"|'
    tlc_case webview kitty_lean_webview pass
    tlc_case webview-stream-before-mount kitty_lean_webview fail '' 's|Bug = "none"|Bug = "early"|'
    tlc_case webview-no-outbox kitty_lean_webview fail '' 's|Bug = "none"|Bug = "nobox"|'
    tlc_case webview-answers-to-all kitty_lean_webview fail '' 's|Bug = "none"|Bug = "broadcast"|'
    tlc_case webview-sessions-kept kitty_lean_webview fail '' 's|Bug = "none"|Bug = "keep"|'
    tlc_case webview-hello-without-server kitty_lean_webview fail '' 's|Bug = "none"|Bug = "greetonce"|'
    tlc_case webview-forgotten-page-carries-on kitty_lean_webview fail '' 's|Bug = "none"|Bug = "noreload"|'
    tlc_case start-waiters-not-rearmed kitty_lean_start fail 's|/\\ ensure'"'"' = ensure \\cup {g \\in waiting : buf\[g\] = "open"}|/\\ UNCHANGED ensure|'
    rm -rf "$tmp"
fi
exit $status
