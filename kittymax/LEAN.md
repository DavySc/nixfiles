# Lean 4: kittymax next to VS Code

Every feature of the official VS Code extension
([vscode-lean4](https://github.com/leanprover/vscode-lean4), its manual and
source), and what kittymax does instead. **done**: the same job, the same way
or close; **partial**: the job, but less of it; **gap**: not there.

The pieces: [nael](https://codeberg.org/mekeor/nael) (the major mode, `\`
abbreviations, eglot setup for `lake serve`), eglot (the LSP client),
`lisp/lang/kitty-lean.el` (the infoview, file progress, Lake, Org and the rest
below), `lisp/lang/kitty-lean-widgets.el` (Lean's widgets as text),
`lisp/lang/kitty-lean-webview.el` (VS Code's own infoview in a webview, `\w`),
elan from Nix to fetch each project's toolchain.

Tested against Lean 4.35 and a real Lake project in `test/kitty-lean-test.el`
(64 tests): the server, diagnostics, the infoview, progress, completion,
definitions, hovers, `\` input, sorry, `Try this`, restart, `lake build` and
run, and Org blocks with `C-c '`. Most of the rest are regression tests from
two reviews that tried each feature against real Lean: K on subterms, session
loss, pause, edits racing questions, failed, slow and hidden server starts,
narrowed buffers, wide characters, and how fast Lean checks with the infoview
open; the webview, served and relaying a real server; and eglot-booster left
to buffering, since its bytecode mode garbles `⊢`. Eight TLA+ models
(`test/kitty_lean*.tla`) cover the timing: the infoview's refresh, the RPC
session, one server per project (with the selected buffer and eglot's
connect timeout), folds and buttons answered late (a trace's children,
`[apply]` after an edit), diagnostics taken in pieces, the webview's
calls, event streams and pages, when a page is told the server
restarted, and the editor's folding ranges, asked again for each text.
TLC checks each model, and also checks that it rejects the broken
versions that the reviews found.

## Editing

| VS Code | kittymax | |
| --- | --- | --- |
| Language server per project (`lake serve`), standalone files too | eglot with `lake serve`, project from `lakefile.lean` / `lakefile.toml`; one server however many files open at once | done |
| A first start shows elan's toolchain download, however long it takes | no connect timeout for Lean; the mode line shows what `lake` prints while it starts (` Lean starting: info: downloading…`) | done |
| Syntax highlighting (TextMate) + semantic highlighting | nael's font-lock + eglot's semantic tokens (Emacs 31) | done |
| Diagnostics: squiggles, Problems view | flymake: underlines, margin dots, end-of-line text; `SPC x x` project list; `]d` `[d` | done |
| Diagnostics in pieces while Lean checks (`incrementalDiagnosticSupport`), handed on in batches | the same: each message comes once, flymake gets them at most every 0.1 s (a file with 2000 messages: 3 MB of JSON and 1 s of Emacs' time, instead of 420 MB and 31 s) | done |
| File progress: orange bars in the gutter, status bar | fringe bars on lines still being checked; ` ⧗ 42%` in the mode line (doom-modeline's misc-info) | done |
| "Unsolved goals" / "Goals accomplished" gutter decorations (Lean ≥ 4.20) | ✓ in the right fringe beside a finished proof (at the end of the line in a terminal), 🛠 after the last line of one with goals left; Lean's silent "Goals accomplished!" kept out of flymake and the infoview, as VS Code does | done |
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
| Folding: Lean's folding ranges (declarations, namespaces, imports, comments; proofs in Lean ≥ 4.37), Fold / Unfold All Proofs | kittymax asks Lean for them (eglot does not) each time it finishes checking, and hideshow folds them: `za` `zc` `zo` `zM` `zR`; `\z` / `\Z` fold / unfold all proofs (not `lean4.foldProofsByDefault`) | done |
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
| Messages at the cursor, full text | "Messages" section; a message spanning lines shows on each of them; interactive (its terms answer `K` and `gd`), since kittymax now tells Lean it can show widgets (`hasWidgets`, as VS Code does) | done |
| All Messages, with a count, sort, pause | a folded "All messages: 2 errors, 0 warnings, 1 info" section: `TAB` lists every message (its first line, `RET` jumps there); `SPC x x` too | done (first lines only) |
| Hover a term in the infoview: its type, docs, and hovers inside that | `K` on it, in a help buffer, the docstring as Markdown (no `K` inside that) | partial |
| Go to definition from the infoview | `RET` / `gd` | done |
| Pin a position: its whole state stays on screen in any file; unpin it, go to it | `\x` pins the goals (not the expected type or messages), shown in every file; `RET` on it goes there, `u` unpins it, `\c` clears all | partial |
| Go to the infoview | `\ TAB` | done |
| Pause, and refresh while paused | `\p`, or `p` in the infoview; no refresh while paused | partial |
| Hide instances / types / inaccessible names / let values; emphasize first goal; reverse order; goal diffs on or off | `\v`: diffs, types, instances, let values, target first (reverse), only the first goal unfolded (`\dd` diffs); inaccessible names (`a✝`) dimmed | done |
| Diff against a pinned position (lean.nvim's `\dx`) | none | gap |
| Collapse goals and sections | `TAB` (or `za`, or a click on ▾ ▸) folds a section, a goal (each titled by its case when there are several), a trace node, a widget's `<details>`; folds stay as you left them across refreshes | done |
| Copy a goal to the editor / as a comment | yank from the infoview buffer | partial |
| Widgets: `Try this` buttons, ProofWidgets, `conv?` shift-click, user widgets (React) | all of them, drawn by VS Code's own infoview in a webview beside the code: `\w` (below). In the text infoview, drawn as text from the widget's data (lean.nvim's way): `Try this` `[apply]` buttons (`RET` / click; refused if the file changed since), error-code explanations, ProofWidgets HTML (headings, lists, bold / italic / code, colours, links, tables, `<details>`, MakeEditLink, interactive terms) and `<svg>` as an image in a graphical Emacs. Widgets that need their own JavaScript (Penrose diagrams, `conv?`'s selection panel, plots, custom React) show their name and point to `\w` | done (`\w`) |
| Trace explorer (expandable `trace` messages) | each trace node a fold, classes shortened under their parent; children asked from Lean only when opened (`lazyTraceChildrenToInteractive`, as VS Code), and again on each refresh while open (VS Code keeps them); flymake's copy of a trace message is "(trace: unfold it in the infoview)", since Lean sends only "(trace)" once widgets are on, as VS Code's Problems shows it; no trace search | done (no search) |
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

## VS Code's own infoview: `\w`

`\w` opens the infoview VS Code shows, the same code (vscode-lean4's
`@leanprover/infoview` package, from npm through Nix), beside the Lean file:
in an xwidget webview in graphical Emacs (nixpkgs' emacs-pgtk is built with
xwidgets), or in your browser from a terminal Emacs.  Emacs is its editor:
it serves the page on 127.0.0.1 (a random port and a secret path) and
relays between it and the `lake serve` eglot already runs, as VS Code's
extension does.  So everything VS Code's infoview draws, it draws:
widgets with their own JavaScript (Penrose, plots, `conv?`'s subterm
selection, custom React), hovers inside hovers, pins, the gear's view
settings.  Its clicks act in Emacs: `Try this` edits the buffer,
Ctrl-click opens the definition, "Restart File" restarts it.  Its
right-click menu is VS Code's (go to definition, select, pin, pause, copy
state or message, trace search, and the "Settings…" entries), drawn by the
page, since VS Code draws it outside the webview.

What it costs, measured with Chromium on Lean 4.35:

| | time |
| --- | --- |
| page up, infoview ready | 0.3 s |
| goal of a small proof after a cursor move | 60 ms (50 of them the infoview's own debounce, as in VS Code; the relay through Emacs 3 ms) |
| a goal of 300 hypotheses (Lean's answer 214 kB) | 380 ms (Lean 275 ms, the relay 4 ms; the text infoview draws it in 12 ms once Lean answers) |
| 2000 messages, All Messages opened | 0.3 s; the page's JavaScript heap 40 MB (110 MB with the 300-hypothesis goal) |

Lean's answers reach the page as the exact JSON Lean sent (eglot's JSON-RPC
keeps it), so Emacs neither parses them twice nor loses `{}` from `null`.
Only the page's own files are served, and only under the secret path; a
browser is sent there through a private file, so the secret is not on its
command line.  A page whose connection stays down a minute (a laptop
asleep) is forgotten, its RPC sessions let go, and it reloads when it is
back.  The webview (WebKit's processes) takes about 280 MB of memory
beside Emacs.
The text infoview stays (`\i`): it is what a terminal without a browser has,
and it is lighter.

## What cannot

| | why |
| --- | --- |
| Pictures inside a terminal Emacs (kitty's graphics protocol) | Emacs 31 does not speak it; a terminal Emacs opens `\w` in a browser instead |
| Math in hover Markdown (KaTeX) in the text infoview | `K` shows the TeX; `\w`'s hovers render it |

The remaining gaps: sticky scroll, and VS Code's project management (module hierarchy, lakefile schema, elan UI,
setup diagnostics).
