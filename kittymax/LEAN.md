# Lean 4: kittymax next to VS Code

Every feature of the official VS Code extension
([vscode-lean4](https://github.com/leanprover/vscode-lean4), its manual and
source), and what kittymax does instead. **done**: the same job, the same way
or close; **partial**: the job, but less of it; **gap**: not there.

The pieces: [nael](https://codeberg.org/mekeor/nael) (the major mode, `\`
abbreviations, eglot setup for `lake serve`), eglot (the LSP client),
`lisp/lang/kitty-lean.el` (the infoview, file progress, Lake, Org and the rest
below), elan from Nix to fetch each project's toolchain.

Tested against Lean 4.35 and a real Lake project in `test/kitty-lean-test.el`
(39 tests): the server, diagnostics, the infoview, progress, completion,
definitions, hovers, `\` input, sorry, `Try this`, restart, `lake build` and
run, and Org blocks with `C-c '`. Most of the rest are regression tests from
two reviews that tried each feature against real Lean: K on subterms, session
loss, pause, edits racing questions, failed, slow and hidden server starts,
narrowed buffers, wide characters, and how fast Lean checks with the infoview
open. Three TLA+ models (`test/kitty_lean*.tla`) cover the timing: the
infoview's refresh, the RPC session, and one server per project (with the
selected buffer and eglot's connect timeout). TLC checks each model, and also
checks that it rejects the broken versions that the reviews found.

## Editing

| VS Code | kittymax | |
| --- | --- | --- |
| Language server per project (`lake serve`), standalone files too | eglot with `lake serve`, project from `lakefile.lean` / `lakefile.toml`; one server however many files open at once | done |
| A first start shows elan's toolchain download, however long it takes | no connect timeout for Lean; the mode line shows what `lake` prints while it starts (` Lean starting: info: downloading…`) | done |
| Syntax highlighting (TextMate) + semantic highlighting | nael's font-lock + eglot's semantic tokens (Emacs 31) | done |
| Diagnostics: squiggles, Problems view | flymake: underlines, margin dots, end-of-line text; `SPC x x` project list; `]d` `[d` | done |
| File progress: orange bars in the gutter, status bar | fringe bars on lines still being checked; ` ⧗ 42%` in the mode line (doom-modeline's misc-info) | done |
| "Unsolved goals" / "Goals accomplished" gutter decorations (Lean ≥ 4.20) | the infoview says "No goals"; no gutter mark at the end of a proof | gap |
| Hover (type, docstring) | eldoc in the echo area, `K` for the full doc | done |
| Completion: identifiers, dot, tactics, structure fields, imports | corfu on eglot's completion | done |
| Signature help | eldoc | done |
| Inlay hints (auto-bound implicits) | eglot's inlay hints | done |
| Occurrence highlighting | eglot's documentHighlight | done |
| Go to definition / declaration / type definition | `gd`, `gD`, `grt`; into Lean's and dependencies' sources, opened read-only | done |
| Find references, workspace symbols | `grr` / `SPC c l`, `xref-find-apropos` | done |
| Rename | `grn` / `SPC c n` | done |
| Call hierarchy | `M-x eglot-show-call-hierarchy` (Emacs 31) | done |
| Outline, breadcrumbs, go to symbol | `gO` / `SPC c s` (imenu), `SPC s i` all buffers | done (no breadcrumbs bar) |
| Folding (proof folding in Lean ≥ 4.37) | none (eglot has no folding ranges) | gap |
| Sticky scroll | none | gap |
| Code actions: `#guard_msgs` update, imports for unknown identifiers, `Try this` | `gra` / `SPC c a` for all of them; `\s` takes a `Try this` at once | done |
| Restart File (`Ctrl+Shift+X`), Restart Server | `\r` / `SPC m R` (rebuilds out-of-date imports), `\R` (also a start that hangs) | done |
| Opening a file does not build its imports (`lean4.automaticallyBuildDependencies` off): Lean says they are out of date, Restart File builds them | the same (`dependencyBuildMode` never on open, once on `\r`); `kitty-lean-build-dependencies` builds on open | done |
| Read-only dependencies and toolchain sources | `.lake/packages`, `~/.elan/toolchains`, `/nix/store` open read-only | done |

## Unicode input

| VS Code | kittymax | |
| --- | --- | --- |
| `\` abbreviations, the same table | nael's table (from vscode-lean4's `abbreviations.json`), plus the 15 it lacks and `\\` for `\`; not `\+ ` (an Emacs abbreviation has no space) | done |
| Eager replacement: `\forall` becomes `∀` the moment nothing longer can follow | the same: replaced as soon as the abbreviation is complete and no longer one starts with it | done |
| Space, Tab, or any other character finishes it; an unfinished one (`\alp`) becomes the shortest abbreviation it starts (`α`) | the same: space, punctuation, any character that makes it the start of none, TAB (only the symbol, no indentation), leaving insert state | done |
| `\<>` puts the cursor between `⟨` `⟩` | the same | done |
| Hover shows how to type a symbol | `\\` on the symbol ("how to type this") | done |
| Symbol picker, insert or copy | `\u` (consult over the table, insert) | done |
| Custom leader, custom translations | nael's `nael-abbrev-*` tables, in `local.el` | done |
| In Markdown / other languages via settings | in Org `lean` blocks (below) | partial |

## Infoview

| VS Code | kittymax | |
| --- | --- | --- |
| Opens with the first Lean file, follows the cursor | `*Lean Infoview*` side window (right on wide frames, bottom otherwise), refreshed when you stop moving and when Lean finishes checking | done |
| Tactic state: goals, case names, hypotheses | done, from `Lean.Widget.getInteractiveGoals` (falls back to `$/lean/plainGoal`) | done |
| Goal diff highlighting (what this tactic changed) | inserted / removed parts coloured | done |
| Expected type (term mode) | "Expected type" section (`getInteractiveTermGoal`) | done |
| Messages at the cursor, full text | "Messages" section; a message spanning lines shows on each of them | done |
| All Messages, with a count, sort, pause | the tally line ("All messages: 2 errors, 0 warnings, 1 info"); the list itself is `SPC x x` | partial |
| Hover a term in the infoview: its type, docs, and hovers inside that | `K` on it, in a help buffer (no `K` inside that) | partial |
| Go to definition from the infoview | `RET` / `gd` | done |
| Pin a position: its whole state stays on screen in any file; unpin it, go to it | `\x` pins the goals (not the expected type or messages), shown in every file; `RET` on it goes there, `u` unpins it, `\c` clears all | partial |
| Go to the infoview | `\ TAB` | done |
| Pause, and refresh while paused | `\p`, or `p` in the infoview; no refresh while paused | partial |
| Hide instances / types / inaccessible names / let values; emphasize first goal; reverse order; goal diffs on or off | `\v` turns diffs, types and instances on or off (`\dd` diffs); inaccessible names (`a✝`) shown dimmed | partial |
| Diff against a pinned position (lean.nvim's `\dx`) | none | gap |
| Collapse goals and sections | none | gap |
| Copy a goal to the editor / as a comment | yank from the infoview buffer | partial |
| Widgets: `Try this` buttons, ProofWidgets, `conv?` shift-click, user widgets (React) | `Try this` through `\s` / code actions; no rendering of other widgets | gap |
| Trace explorer (expandable `trace` messages) | traces as plain text | gap |
| Theming | your Emacs theme's faces | done |

## Projects, Lake, elan

| VS Code | kittymax | |
| --- | --- | --- |
| New project (standalone / Mathlib) | `SPC m n`, `:LeanNew name [math]` (Mathlib: with the cache) | done |
| Open / download a project | `git clone` + open (no command) | gap |
| Build (fetching the Mathlib cache first), clean, update dependency, fetch Mathlib cache (also per file), select the project's Lean version | `SPC m m` (the Mathlib cache first, as VS Code; errors as jumps, `C-u` for a target), `SPC m c` cache get; clean, update and the rest by hand: `SPC m l` / `:Lake ...` | partial |
| Run a file's `main` | `SPC m r` (`lake env lean --run`) | done |
| Select toolchain, update channels, elan default, uninstall | `elan` on the command line (`:!elan ...`); kittymax ships elan | partial |
| Install elan when missing | elan comes with kittymax on Nix; on Windows, elan's own installer | partial |
| `lakefile.toml` schema (completion, validation) | none | gap |
| Module hierarchy (imports / imported by), copy module name | none | gap |
| Project search in Lean's and dependencies' sources | `\/` (ripgrep), `\f` (files) over the project, `.lake/packages`, and the toolchain's `src/lean` | done |
| Loogle | `\l`: asks, lists the hits with type and module, inserts the one picked | partial (no LoogleView panel) |
| Setup diagnostics (missing elan / git / curl, old Lean) | one message when `lake` is missing, and the commands say why they can't; nothing else | partial |
| Output view, server log | `M-x eglot-events-buffer` (off by default for speed) | partial |

## Org (what VS Code does not have)

- **Babel**: a `#+begin_src lean` block runs with `C-c C-c`; `#eval` and
  `#check` come back as the result. `:project DIR` (or
  `kitty-lean-org-project`, or the org file inside a project) runs it with
  `lake env lean`, so `import Mathlib` works.
- **`C-c '`** on a block opens it with the whole language server: goals,
  infoview, diagnostics, completion. The block is a file under the project's
  `.lake/` (or kittymax's cache) for as long as you edit it.
- `\` abbreviations work inside `lean` blocks in the org buffer itself.
- Tangling writes `.lean`; `<le` + `TAB` inserts a block.

## The gaps that matter most

1. **Widgets** (ProofWidgets, `conv?`, custom user widgets): VS Code renders
   React; nothing in Emacs does. `Try this` (the common one) works.
2. **Infoview collapse / settings** and the **All Messages** list inside the
   infoview.
3. **End-of-proof gutter decorations** and the **trace explorer**.
4. **Module hierarchy**, **lakefile schema**, **elan UI**, **setup
   diagnostics**: VS Code's project management; here it is the shell.
