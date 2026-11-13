# kittymax

An Emacs with my Neovim config's keys, for the jobs Emacs does best (org,
magit, dired, elfeed ...) without retraining my fingers: Neovim
([my-nvim](https://github.com/DavySc/my-nvim)) is the main editor and the
source of truth for every key. evil, catppuccin mocha, built for NixOS and
native Windows, fast to start, and good at the things I write: org, markdown,
C, C++, C#, OCaml, SQL, Soufflé, Verilog / SystemVerilog, Nix.

On my Windows work machine it stands in for two heavy programs: **SQL Server
Management Studio** ([Databases](#databases-in-place-of-ssms)) and **Visual
Studio** for C and C# ([C and C#](#c-and-c-in-place-of-visual-studio)), at a
fraction of their memory, with the same keys as everything else.

```
early-init.el        before the first frame: GC off, no flash, package-quickstart
init.el              loads the modules below
lisp/kitty-platform  Nix vs Windows: state directories, where packages come from
lisp/kitty-packages  the package list; installs it from ELPA/MELPA without Nix
lisp/kitty-lib       loader (compiles into the cache), keymap helpers, the leader maps
lisp/kitty-core      defaults, performance, state directories
lisp/kitty-ui        catppuccin mocha, doom-modeline, fonts, icons, which-key, splash
lisp/kitty-cat       a kitten gives you a paw when you save
lisp/kitty-evil      Vim keys and the SPC leader tree, as in my-nvim
lisp/kitty-vim       my-nvim's operators, text objects and multiple cursors
lisp/kitty-completion vertico orderless marginalia consult embark corfu cape
lisp/kitty-vc        magit, diff-hl
lisp/kitty-dired     dired + dirvish
lisp/kitty-org       org-mode
lisp/kitty-org-tools clocking, habits, export (HTML, PDF, Word), babel, org-roam
lisp/kitty-ob-csharp C# org blocks through .NET 10's file-based apps
lisp/kitty-markdown  the markdown editing experience
lisp/kitty-prog      tree-sitter, eglot (+ emacs-lsp-booster), flymake, apheleia
lisp/kitty-rss       elfeed: RSS and Atom feeds
lisp/lang/           c (+ msvc), csharp, ocaml, sql (+ dbbliss, sqldiff), souffle, verilog, nix
package.nix          Emacs with all packages + language servers + tools = `kittymax`
windows/             kittymax.cmd (launcher) and install.ps1 (winget) for native Windows
test/                ERT tests (test/run.sh)
```

## Install

It is wired into `home.nix` already: `sudo nixos-rebuild switch --flake ~/nixos-config#wsl`,
then `kittymax` (a window through WSLg) or `kittymax -nw`.

The Lisp is **not** in the Nix store: `~/.config/kittymax` is a symlink to this
directory, so editing a file and `SPC R` (reload) needs no rebuild. Adding a
package or a tool to `package.nix` does.

Per-machine settings go in `kittymax/local.el` (git-ignored): `org-directory`,
`kitty-font-size`, SQL connections ...

## Native Windows

The same configuration runs on Windows without Nix. The difference is only
where things come from: instead of the Nix profile, Emacs installs its
packages from ELPA and MELPA on the first start (a few minutes, once), into
`%LOCALAPPDATA%\kittymax\data\elpa`. Nothing is written into the checkout.

1. Clone the repository, e.g. `git clone <url> %USERPROFILE%\nixos-config`.
2. Run the installer (needs `winget`, which Windows 10/11 has):

   ```
   powershell -ExecutionPolicy Bypass -File windows\install.ps1
   ```

   It installs Emacs, git, ripgrep, fd, clangd + clang-format + clang (LLVM),
   CMake, Ninja, the .NET 10 SDK, netcoredbg, sqlcmd, pandoc, MiKTeX and the
   JetBrainsMono Nerd Font (every winget id checked against winget-pkgs), then
   `csharp-ls` as a dotnet tool, CodeLLDB (the C debugger) from its release,
   and the database client's backend (unless Neovim built it already), and
   puts a `kittymax` shortcut on the desktop. Or install those yourself.
   Visual Studio is not installed: its compiler and MSBuild are used when they
   are there (or the smaller Build Tools for Visual Studio).
3. Start it with the shortcut or `windows\kittymax.cmd [file]`. That is
   `emacs --init-directory <checkout>\kittymax`.

Different on Windows:

- **Tree-sitter grammars** are not bundled. Emacs offers to build the one a
  file needs; kittymax builds it with clang from LLVM (which `install.ps1`
  installs) and Visual Studio's linker, since Windows has no `cc`. Until a
  grammar is there the classic mode of that language is used, which is fine,
  and the tree-sitter text objects (`if` / `af` calls, `S`, `an` / `in`) fall
  back or say so. With no C compiler at all nothing is offered. Built
  grammars go to `%LOCALAPPDATA%\kittymax`'s data, once.
- **Not installed** because they need a Unix pty, a native module or a binary
  Windows lacks: `eat` (`SPC t t` and `C-/` open eshell instead; Claude Code
  on `SPC a` needs eat, so it is not there), `jinx` (spell
  checking uses flyspell if aspell/hunspell is on `PATH`), `eglot-booster`.
- **Language servers and tools** that winget has no package for: install
  verible, verilator and iverilog (hardware), sqls (SQL) and souffle (Datalog:
  built with CMake and MSVC) yourself and put them on `PATH`; kittymax uses
  what it finds. sqldiff: install Rust (`winget install
  Rustlang.Rustup`) and `cargo install --git https://github.com/DavySc/SQLDiff
  sqldiff-cli`, which puts `sqldiff.exe` in `%USERPROFILE%\.cargo\bin`.
  Without it the SQL lint and diff are off; T-SQL formatting wants sqlfluff
  (`pip install sqlfluff`).
- `SPC f u` (sudo) does not exist; pasting an image from the clipboard
  (`SPC m i p`) goes through PowerShell; dired uses Emacs's own `ls`.
- State is under `%LOCALAPPDATA%\kittymax` (`data` kept, `cache` disposable,
  e.g. the compiled configuration).

`KITTYMAX_PACKAGES` picks the package source: `nix` (set by the Nix wrapper),
`none` (use what is installed, never touch the network) or unset (install from
ELPA). `KITTYMAX_FRAME=windowed` or `maximized` replaces the full-screen start.
`M-x kitty-install-packages` retries a failed install.

## Keys

They are my-nvim's. Neovim is the source of truth: a key it defines does the
same thing here, and Emacs-only commands sit on keys it leaves free, so
nothing here teaches a habit that is wrong in Neovim.

**Vim**, through evil, with my-nvim's settings: relative line numbers,
`ignorecase` + `smartcase`, `scrolloff` 6, undo kept across restarts
(undo-fu-session), `Y` to the end of the line, `C-u` / `C-d` scroll, splits
to the right and below, `f` / `t` across lines, `:s` previewing as you type.
`C-k` in insert mode is Vim's digraphs. `C-x` stays Emacs's prefix key (Vim's
decrement is `-1 C-a`); `C-h` is Emacs's help.

| Key | What (as in my-nvim) |
| --- | --- |
| `s` | jump to anything on screen (flash → avy), also after an operator |
| `S`, visual `an` / `in` | select a syntax node, grow / shrink it (tree-sitter) |
| `ys{motion}{char}`, `cs`, `ds`, visual `gs` | surround (`*` makes `**bold**` in markdown) |
| `ga{motion}{char}` | align: `gaip=` |
| `gc{motion}`, `gcc` | comment |
| `ia` `if` `iq` `ib` (and `a...`) | argument, call, any quote, any bracket (mini.ai) |
| `iN(` `aL"` ... | the next / last pair of that kind: `ciN(` |
| `ih` | the changed hunk: `dih`, `yih` |
| `C-n` / `SPC M` / `Q` | a cursor on the next match / every match / here; `]C` `[C` between them, `C-l` clears (so does `Esc` for match cursors), `gQ` brings them back. Match cursors are evil-multiedit (one edit mirrored into every match: instant with thousands), `Q`'s are evil-mc |
| `gd` `gD` `grr` `gri` `grn` `gra` `grt` `gO` `K` | the language server (eglot), Neovim 0.12's keys; `C-s` in insert mode: signature |
| `]d` `[d`, `C-w d` | next / previous diagnostic, the one under the cursor |
| `]h` `[h` | next / previous changed hunk |
| `-` | the file's directory (dired as oil, below) |
| `C-/` | a terminal that pops up and away |
| `C-a` | the number (in org: the date) under or after the cursor, up |
| `C-n` `C-p` `C-y` `C-e`, `Tab` | completion: pick, accept, close; Enter only accepts what you picked |

**The leader** is `SPC` (which-key shows it), laid out as my-nvim's:

| | | | |
| --- | --- | --- | --- |
| `SPC f f` find files | `SPC f g` grep | `SPC ,` buffers | `SPC e` file tree |
| `SPC g` git (`g` magit, `h` file history) | `SPC h` hunks (`s` stage, `r` reset, `p` preview) | `SPC x` diagnostics | `SPC c a` / `SPC r n` code action / rename |
| `SPC c s` symbols | `SPC d` debug (dape) | `SPC a` Claude Code | `SPC o a` / `SPC o c` agenda / capture |
| `SPC u` toggles (`k` kitten, `z` zen, `u` undo tree, `h` hints, `p` org symbols) | `SPC f r` registers, `SPC f t` terminal | `SPC p v` dired | `SPC R` reload, `SPC X` eval line |
| `SPC SPC x` eval this file | `SPC m` **this mode's keys** | | |

Emacs-only, on prefixes my-nvim leaves free: `SPC b` buffers, `SPC p` projects,
`SPC s` search, `SPC n` notes (with org-roam's linked notes), `SPC t` tools
(terminal, eshell, rss, `t s` connect to a database, markdown preview),
`SPC i` insert, `SPC q` quit, `SPC H` help, `SPC :` M-x.

`SPC m` changes with the mode; where my-nvim has the same keys they match:
`SPC m m` builds (C) or lints (Verilog), `SPC m r` runs, `SPC m d` debugs,
`SPC m g` configures, `SPC m a` switches source / header, `SPC m w` opens
waves.

**Org** has nvim-orgmode's keys: `cit` / `ciT` TODO state, `cid` date, `ciR` /
`cir` priority, `<<` / `>>` on a heading, `TAB` / `S-TAB` folding, `C-SPC`
checkbox, `}` `{` `]]` `[[` `g{` headings, and `SPC o ...` (`r` refile, `t`
tags, `$` archive, `i d` / `i s` deadline / schedule, `l i` link, `x i` / `x o`
clock, `SPC RET` new heading or item). In capture buffers `C-c` files it. The
agenda: `f` / `b` later / earlier, `.` today, `vd` `vw` `vm` views, `t` todo,
`J` a date, `r` redo, `q` quit.

**Ex commands**: Vim's (`:w` `:q` `:e` `:s` `:g` ...) and my-nvim's `:Format`,
`:Ex`, `:Oil`, `:Neogit`, `:Undotree`, `:KittenPaw`, `:ConfigReload`.

## When you save

A kitten in the echo area blinks and gives you a paw:

```
 /\_/\  <3
( ^.^ )__o
 > ^ <   saved notes.org
```

It takes about a second and blocks nothing: any key sends it away, and
`=^.^= saved notes.org` stays behind. It plays only for the buffer you are
looking at, never over a minibuffer prompt, and once per save even when a
formatter saves again. `SPC u k` turns it off (`(kitty-cat-mode -1)` in
`local.el` to keep it off), and `M-x kitty-cat-paw` calls it whenever you need one.

## Files: dired as oil

`-` opens the file's directory with the cursor on it (`nvim .`'s oil). Like oil,
the listing is text you edit: `i` `a` `c` ... start editing names (wdired),
`dd` marks a file for deletion, and `:w` applies it all. `-` goes up, `RET`
opens, `C-p` previews, `g.` hides dotfiles, `gd` shows sizes and dates, `ga`
jumps to home, projects, nixos-config or `~/.config`, `q` closes. `SPC e` is
the sidebar tree.

## Markdown

`.md` is `gfm-mode`. Prose in a proportional font in a centred column, headings
scaled, tables aligned (valign), code in monospace. Markup (`**`, `#`, backticks,
link targets) is hidden except on the line you are on. Lists, checkboxes and
tables continue as you type; `RET` on a link follows it, on a task toggles it.
Images show inline; `SPC m i p` pastes one from the clipboard into `assets/`.
Code blocks are highlighted in their language, `SPC c e` (or `SPC m e`) edits one in its own
buffer. marksman completes and checks links and headings, `SPC m p` previews
live, `SPC m E` exports with pandoc, `SPC m i T` writes a table of contents.
Prettier formats on request only (`SPC c f`), never on save.

## RSS

`SPC t r` opens elfeed and fetches every feed. The feeds are an org file,
`elfeed.org` in `org-directory` (elfeed-org), created with a few examples the
first time; `SPC t R` opens it. One feed link per heading, under a heading
tagged `:elfeed:`; tags are inherited, so feeds under `** Emacs :emacs:` are
tagged `emacs`. Set `kitty-rss-feeds-file` in `local.el` to keep it elsewhere.

In the list: `j` `k` move, `RET` reads, `b` opens in the browser, `s` filters
(`+emacs`, `@1-week-ago`, words), `g` / `G` refresh / fetch, `u` `r` unread /
read, `q` quits and saves. `SPC m` has mark all read, starring and ready-made
filters. Entries are shown wrapped and centred like markdown.

## Languages

| | server | format | `SPC m` |
| --- | --- | --- | --- |
| C / C++ | clangd | clang-format (with a `.clang-format`) | `m` build, `r` run, `d` debug, `g` configure / compile_commands, `a` header/source, `T` ctest |
| C# | csharp-ls | the server, on save | `m` build, `r` run, `d` debug, `t` test at point, `T` class, `A` all, `w` watch, `p` package |
| OCaml | ocaml-lsp | ocamlformat (on save with a `.ocamlformat`), `dune format-dune-file` | `m` build, `c` check, `r` run, `d` debug, `t` / `T` test, `w` watch, `p` promote, `a` ml/mli, `u` utop (below) |
| SQL | sqls (`SPC m L`), sqldiff (flymake) | by dialect, see below | the database client (below), sqldiff (`D` with file, `k` check), `t` dialect |
| Soufflé | | | `m` check and run (errors are jumps), `r` run with facts from the file's directory |
| Verilog, SystemVerilog | verible | verible | `m` verilator lint, `r` iverilog + vvp, `w` gtkwave, AUTOs, templates |
| Nix | nil | nixfmt | rebuild |

Verilog buffers are also linted by verilator as you type (flymake), for the
checks a language server does not do: widths, unused and undriven signals.

C# needs the .NET SDK: kittymax carries one, a project's dev shell wins.

Soufflé (`.dl`) is highlighted as my-nvim's `syntax/souffle.vim` does it;
`SPC m m` runs `souffle -F <dir> -D - file.dl` in the file's directory, as
my-nvim's `:make`, and `RET` on a message lands on its line and on the column
its `^` points at. `.facts` files keep their Tabs, show them, and are never
stripped of trailing whitespace on save (a trailing Tab is an empty column).

### SQL dialects

kittymax works with T-SQL (SQL Server), PostgreSQL and Db2 for i, and never
guesses which one a file is written in. The dialect comes from, in order:

1. `kitty-sql-dialect`, set in `.dir-locals.el` (`SPC m t` offers to write it)
   or in the file's first line (`-- -*- kitty-sql-dialect: tsql -*-`):

   ```elisp
   ((sql-mode . ((kitty-sql-dialect . db2i))))
   ```

2. the file name: `foo.tsql.sql`, `foo.pg.sql` (or `.pgsql`), `foo.db2i.sql`;
3. `kitty-sql-default-dialect` from `local.el`, which is nil out of the box.

The mode line shows it (`SQL[tsql]`), and it decides:

| dialect | highlighting | format on save | sqldiff |
| --- | --- | --- | --- |
| `postgres` | PostgreSQL | pg_format | yes |
| `tsql` | SQL Server | sqlfluff | yes |
| `db2i` | Db2 | none | yes |
| not known | PostgreSQL | none | off |

[sqldiff](https://github.com/DavySc/SQLDiff) runs as you type (flymake):
residue from other dialects, a missing `;` before `THROW`, parse problems.
`SPC m D` compares the file with another one. It offers the same object in
another dialect (`foo.tsql.sql` next to `foo.db2i.sql`) and shows the verdict
and every behavioural difference in `*sqldiff*`: `RET` jumps to either side,
`g` reruns, `e` opens ediff. After `SPC m f` (format), sqldiff compares before
and after and warns if the formatter changed what the code means.

## OCaml

tuareg for `.ml` / `.mli` (and menhir `.mly` and opam files), dune-mode for
dune files, ocaml-lsp through eglot: types on hover (`K`), `gd`, `grr`, `grn`,
code actions (`gra`: add a type annotation, destruct a value into its cases,
construct an expression for a `_` hole, extract a local or a function),
diagnostics from the compiler at the end of the line, `]d` / `[d`. Everything runs at the **dune root** (the outermost
`dune-workspace`, else the outermost `dune-project`, as dune finds it), so the
paths in errors resolve and every error and warning is a jump.

| `SPC m` | |
| --- | --- |
| `m` / `c` | `dune build` / `dune build @check` (types only, faster) |
| `r` | `dune exec` an executable of the project (the one next to the file, else ask) |
| `t` / `T` | tests of this directory / of everything |
| `w` | `dune build -w`: errors stay in the buffer as you save |
| `p` | `dune promote`: accept an expect test's output (reloads the buffers) |
| `f` / `F` | format this buffer (ocamlformat, or `dune format-dune-file`) / `dune fmt` everywhere |
| `a` | the other file: `.ml` / `.mli` |
| `u u`, `u e`, `u r`, `u b` | utop: start (loading this directory's library), eval phrase / region / buffer (OCaml's own toplevel when utop is not installed) |
| `d` | debug with ocamlearlybird (dape): builds `main.bc` first; the executable needs `(modes byte exe)` and kittymax tells you when it does not |
| `I` / `E` | install the tools in the project's opam switch / read the opam environment again |

**opam.** The tools come from the project's switch: kittymax runs
`opam env` for the project (a local `_opam` switch when there is one), in the
background, once, and gives the result to that project's OCaml buffers,
commands, utop and the language server. On native Windows: `winget install
OCaml.opam` (`install.ps1` does), `opam init` once, then `SPC m I` in an OCaml
file installs `ocaml-lsp-server`, `ocamlformat`, `dune`, `utop` and `earlybird`.
Under Nix the compiler, dune, ocaml-lsp, ocamlformat, utop and earlybird are in
the wrapper as a fallback, built for one OCaml version: a language server only
works with the compiler version it was built for, so a project's own dev shell
comes first on PATH.

ocaml-lsp needs dune's merlin configuration, which `dune build` writes. The
first time you open a file whose directory has none, kittymax runs one
`dune build @check` in the background and restarts the server when it is done
(until then ocaml-lsp says "No config found").

Editing: `(*` opens a comment `(* | *)`, and `'` is never paired (type variables
`'a`). Style is imposed on save only when the project has a `.ocamlformat`;
`SPC m f` formats anyway (ocamlformat's default profile without one).

dune's output is asked for as `--display=quiet`: its progress line
(`Done: 62% ...`) is redrawn with carriage returns, which a compilation buffer
mishandles: every coloured error after the first progress line stayed as raw
escape codes and no longer matched the error pattern. The same fix is in
`kitty-core.el` for every other tool that colours its errors: escape codes
become faces before the buffer is parsed.

## Databases (in place of SSMS)

The database client is [dbbliss.nvim](https://github.com/DavySc/dbbliss.nvim)'s:
kittymax talks to the same backend process my-nvim uses (a .NET program that
holds the connections), so both editors share one build of it and its rules.
Cancel is protocol-level and works while the server is busy; results are paged
and never lose rows; a `prod` connection asks before any statement that can
change data; an open transaction is never committed or rolled back behind your
back, and quitting with one asks first.

Connections go in `local.el` (git-ignored), as in my-nvim's `lua/local.lua`:

```elisp
(setq kitty-dbbliss-connections
      '(("work" :engine "sqlserver" :env "dev"
         :connection-string "Server=sql01;Database=App;Integrated Security=true;TrustServerCertificate=true")
        ("prod" :engine "sqlserver" :env "prod"
         :connection-string "Server=sql02\\PROD;Database=App;Integrated Security=true")))
```

`Integrated Security=true` is Windows authentication: no password anywhere.
Otherwise `:password` names where one is, never the password: `(:env "NAME")`,
`(:credman "target")` (Windows Credential Manager), `(:pass "path")`.

In a SQL buffer (`SPC m`, or `:Dbbliss <command>` as in my-nvim):

| | |
| --- | --- |
| `c` / `u` / `C` | connect / use another open connection / disconnect |
| `e`, `C-RET` | run the statement under the cursor (SQL Server: its `GO` batch), or the selected lines |
| `a`, `F5` | run the whole buffer (`F5` runs the selection when there is one, as in SSMS) |
| `x` | cancel the running query |
| `T b` / `T c` / `T r` | begin / commit / roll back |
| `d`, `K` | object info: columns, indexes, keys in and out, triggers, definition |
| `S` | the object's CREATE script, in a new buffer |
| `l` | the object explorer: databases, schemas, tables, views, functions, procedures |
| `p` / `P` | estimated plan / actual plan (run in a transaction that is rolled back) |
| `E` | export the statement's result to CSV (the backend writes it) |
| `s` / `R` / `M` | status / results / server messages (PRINT, RAISERROR) |

A script stops at the first statement that fails, says which one, and marks
its line (`]d`). The mode line shows the connection, `PROD`, an open
transaction and a running query. Completion (corfu) offers the connection's
tables and views after `FROM`, `JOIN`, `UPDATE` ..., a schema's objects after
`schema.`, and a table's or alias's columns after `alias.`, from a cache that
never makes you wait.

The results buffer: `TAB` / `S-TAB` cell to cell, `yc` / `yr` / `yC` copy the
cell / row / column (full values, NULL as empty), `]]` / `[[` result sets, `gm`
or going to the end fetches the next 1000 rows of a paused query, `m`
messages. In the explorer: `RET` opens, `i` info, `s` script, `t` selects the
first 1000 rows (SSMS's Select Top 1000), `r` / `R` refresh, `S` system objects.
A plan shows each operator with its cost, estimated → actual rows (with the
factor when they are far apart), time, and the hottest node; `x` opens the
raw plan.

In org, a SQL block runs on a connection and returns its rows as a table:

```org
#+begin_src sql :dbbliss work
select top 10 name, create_date from sys.tables order by create_date desc
#+end_src
```

The backend: my-nvim's copy is used when Neovim has built it (`:Dbbliss
build`); otherwise `windows\install.ps1` (or `M-x kitty-dbbliss-build`) builds
one in kittymax's data directory. It needs the .NET 10 SDK to build, not to run.
Not ported from dbbliss.nvim: the sessions list, backup, drop and `:Dbbliss
ask`; my-nvim has them.

## C and C# (in place of Visual Studio)

**C#** (modern .NET): csharp-ls for definitions, references, rename, code
actions and diagnostics; the solution (`.sln`, `.slnx`) or project above the
file is what builds. `SPC m m` builds (errors once, as jumps); `r` runs the
file's project (`C-u` picks another); `t` runs the test method under the
cursor, `T` its class, `A` all, `l` the last run again (Test Explorer); `d`
builds and debugs it with netcoredbg in dape (breakpoints, stepping, locals,
the REPL: my-nvim's `SPC d` keys); `w` is `dotnet watch`; `p` adds a NuGet
package; `s` opens a project of the solution.

**C** with CMake, Make, or a Visual Studio solution, found in that order:

- *CMake*: `SPC m g` configures (a preset from `CMakePresets.json`, asked once
  per project, else `build/` with Ninja) and exports `compile_commands.json`
  for clangd; `m` builds; `T` runs ctest.
- *Visual Studio solutions* (`.sln` + `.vcxproj`): `m` builds with MSBuild;
  `g` writes `compile_commands.json` from MSBuild's own evaluation of each
  project (include paths, defines, C standard, forced includes, property
  sheets: nothing is built), so clangd sees what the compiler sees. Run it
  again after changing project settings. `M-x kitty-msvc-refresh-env` after a
  Visual Studio update.
- *One file*: `m` compiles it alone with gcc, clang or cl (the first found, as
  my-nvim does), `r` runs it.

On Windows the MSVC environment (`cl.exe`, `INCLUDE`, `LIB`: what a Developer
Command Prompt sets) is read once from Visual Studio's `vcvarsall.bat` and
cached, so CMake with Ninja and nmake work from Emacs. `SPC m d` debugs the
program with CodeLLDB, which reads MSVC's PDBs: breakpoints, stepping,
variables, call stacks. What Visual Studio's debugger does that this does not:
edit and continue, natvis visualizers for STL types, mixed managed/native
debugging. For those, WinDbg (`winget install Microsoft.WinDbg`) or Visual
Studio itself, once in a while.

## Org

Beyond notes, tasks, capture and the agenda (`SPC o a`, `SPC o c`):

- **Agenda** files are every `.org` under `~/org`, as my-nvim's `~/org/**/*`.
- **Clocking**: `SPC o x i` / `o` / `q` / `j` (nvim-orgmode's: in, out,
  cancel, go to), `e` effort, `r` clock table, `l` clock in last. A clock left
  running survives restarting Emacs; the agenda's `R` shows the clock report;
  column view (`SPC m c`) shows effort against time clocked.
- **Habits**: a `TODO` scheduled `.+1d` with `:STYLE: habit` (capture
  template `h`); the agenda draws its consistency graph.
- **Export** (`SPC o e`): HTML, PDF (LaTeX: tectonic when installed, else
  xelatex from MiKTeX or TeX Live), and Word (`w`: org's own export, so
  babel results, macros and includes are in it, then pandoc;
  `~/org/reference.docx` styles it when there is one).
- **Babel**: C and C++ (gcc, else clang), C# (.NET 10's file-based apps:
  top-level code, `:usings`, `:package` for NuGet; each block is compiled
  once, so running it again takes a fraction of a second), SQL Server through
  the database client (`:dbbliss work`, or `:engine mssql` through sqlcmd with
  Windows authentication), shell, Python, Emacs Lisp, Graphviz.
- **LaTeX** fragments preview with `SPC m L` (dvipng from MiKTeX / TeX Live,
  else tectonic and ImageMagick).
- **Linked notes** (org-roam, in `~/org/roam`): `SPC n r` find or create a
  note, `n i` insert a link to one, `n b` backlinks, `n c` capture, `n d t` /
  `y` / `d` today's, yesterday's or a date's daily note.

## Why it starts fast

- Garbage collection is off until startup ends, then gcmh keeps it high while
  typing and collects when idle. File-name handlers are off during startup.
- Packages come from Nix: no package.el network, and package-quickstart merges
  all autoloads into one file (rebuilt when the package set changes).
- The Lisp in this directory is byte-compiled into `~/.cache/kittymax/elc` on
  first use (and again when a file changes); Emacs native-compiles it in the
  background after that.
- Everything optional is deferred: modes load with their files, not at startup.
- evil, the biggest piece (about 140 ms byte-compiled), loads the moment Emacs
  first waits for a key, after the first frame is drawn; the splash has keys
  of its own, and a file named on the command line gets the Vim keys as soon
  as evil is in.
- Rendering and LSP are tuned: `jit-lock` deferral, no bidi scanning, a 4 MB
  process read size, emacs-lsp-booster for JSON, no events buffer, so-long.

`SPC H s` prints what startup cost, module by module.

## Fast as you type

Startup is one thing; every keystroke is another. What a key costs, measured
in a real terminal with a full redraw after each key, files of 1,400–2,000
lines:

| | `j` | `k` | `w` | `C-d` | `C-u` | insert + escape |
| --- | --- | --- | --- | --- | --- | --- |
| C | 4.3 ms | 2.8 ms | 2.2 ms | 3.1 ms | 2.8 ms | 5.5 ms |
| SQL | 4.1 ms | 3.0 ms | 1.9 ms | 3.0 ms | 3.7 ms | 2.6 ms |
| org | 4.5 ms | 2.7 ms | 1.7 ms | 2.9 ms | 2.7 ms | 2.7 ms |
| Emacs Lisp | 2.7 ms | 2.1 ms | 1.6 ms | 2.3 ms | 3.6 ms | 2.5 ms |

All of it well inside one frame (16 ms at 60 Hz). Relative line numbers (for
`5j`) cost under a millisecond of that. Two things that were slow are gone:

- **Diagnostics at the end of the line** are drawn by kittymax, not by
  flymake. Flymake's own way (text on each line's newline) made every `j` / `k`
  take 50–390 ms in a file with many diagnostics; now it is 2–5 ms with 2,000.
- **checkdoc** (docstring advice for Emacs Lisp) no longer runs: it linted the
  whole buffer in Emacs itself after each pause in typing, 400 ms on a big file.

`test/kitty-perf-test.el` keeps it so: it boots the whole configuration, opens
a file in each language and types into it, and fails when something new runs
on every keystroke (pre- and post-command hooks are checked against a reviewed
list) or when a motion or an edit goes over its budget.

Emacs 31 runs flymake checkers only in "trusted" files unless a checker says
it is safe, and none does: out of the box C#, C, SQL and Verilog files would
get no diagnostics at all. kittymax marks its checkers safe (eglot, sqldiff,
verilator: none of them runs the file's code) and trusts its own directory
for the Emacs Lisp byte-compiler, which can.

## When something breaks

A module that fails to load, or a hook function that raises an error, is
reported in `*Warnings*` (`C-h e` shows `*Messages*`) and the rest keeps
working. Emacs itself would stop at the first error: one failing function in a
mode hook switches off syntax highlighting for every buffer of that mode.

## Tests

```sh
kittymax/test/run.sh
```

runs inside kittymax's own Emacs (`KITTYMAX_EMACS` for another). Among them:
OCaml against the real dune (its error lines jumped to, `dune exec`, `dune test`,
bytecode targets), the real ocamlformat, a real ocaml-lsp through eglot
(connecting, the one real error and no more, hover) and a real utop evaluating
a phrase, each skipped when the tool is not installed; the database client against a fake backend that speaks dbbliss's protocol (and
a real process over a pipe), MSBuild's evaluation read back from a real
`msbuild` and the `cl.exe` command lines clangd gets from it, dotnet's and
cl.exe's error lines as jumps, Soufflé's errors against souffle 2.5's own
output, org's clock, habits in the agenda, Word export read back through
pandoc, C and C# blocks really run, org-roam's links in its database, and the
keystroke budgets above. Also: every my-nvim
leader key against the command it should run here (`kitty-keys-test.el`, with
nvim-orgmode's and markdown's buffer-only keys, `C-a` and SQL statements), the
markdown reveal-on-current-line behaviour, the verilator flymake backend against a fake
verilator, the loader and keymap helpers, and a smoke test that loads the whole
configuration with no third-party packages at all and checks it degrades
instead of failing.
