# kittymax

A Doom-inspired Emacs on [meow](https://github.com/meow-edit/meow) (selection
first, then the verb) with catppuccin mocha, built for NixOS. Fast to start,
real multiple cursors, and good at the things I write: org, markdown, C, C++,
C#, SQL, Verilog / SystemVerilog, Nix.

```
early-init.el        before the first frame: GC off, no flash, package-quickstart
init.el              loads the modules below
lisp/kitty-platform  Nix vs Windows: state directories, where packages come from
lisp/kitty-packages  the package list; installs it from ELPA/MELPA without Nix
lisp/kitty-lib       loader (compiles into the cache), keymap helpers, SPC m
lisp/kitty-core      defaults, performance, state directories
lisp/kitty-ui        catppuccin mocha, doom-modeline, fonts, icons, which-key, splash
lisp/kitty-cat       a kitten gives you a paw when you save
lisp/kitty-meow      modal editing and the SPC leader tree
lisp/kitty-mc        multiple cursors on meow's beacon
lisp/kitty-ex        the : command line (:q :w :wq :e :%s ...)
lisp/kitty-completion vertico orderless marginalia consult embark corfu cape
lisp/kitty-vc        magit, diff-hl
lisp/kitty-dired     dired + dirvish
lisp/kitty-org       org-mode
lisp/kitty-markdown  the markdown editing experience
lisp/kitty-prog      tree-sitter, eglot (+ emacs-lsp-booster), flymake, apheleia
lisp/kitty-rss       elfeed: RSS and Atom feeds
lisp/lang/           c, csharp, sql (+ sqldiff), verilog, nix
package.nix          Emacs with all packages + language servers + tools = `kittymax`
windows/             kittymax.cmd (launcher) and install.ps1 (winget) for native Windows
test/                ERT tests (test/run.sh)
```

## Install

It is wired into `home.nix` already: `sudo nixos-rebuild switch --flake ~/nixos-config#wsl`,
then `kittymax` (a window through WSLg) or `kittymax -nw`.

The Lisp is **not** in the Nix store: `~/.config/kittymax` is a symlink to this
directory, so editing a file and `SPC h r` (reload) needs no rebuild. Adding a
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

   It installs Emacs, git, ripgrep, fd, clangd + clang-format (LLVM), the .NET
   SDK, pandoc and the JetBrainsMono Nerd Font, `csharp-ls` as a dotnet tool,
   and puts a `kittymax` shortcut on the desktop. Or install those yourself.
3. Start it with the shortcut or `windows\kittymax.cmd [file]`. That is
   `emacs --init-directory <checkout>\kittymax`.

Different on Windows:

- **Tree-sitter grammars** are not bundled. `treesit-auto` offers to build the
  one a file needs (it needs a C compiler, e.g. from MSYS2); until then the
  classic mode of that language is used, which is fine.
- **Not installed** because they need a Unix pty, a native module or a binary
  Windows lacks: `eat` (`SPC o t` opens eshell instead), `jinx` (spell
  checking uses flyspell if aspell/hunspell is on `PATH`), `eglot-booster`.
- **Language servers and tools** that winget has no package for: install
  verible, verilator and iverilog (hardware) and sqls (SQL) yourself and put
  them on `PATH`; kittymax uses what it finds. `SPC o s` (psql) needs the
  PostgreSQL client tools. sqldiff: install Rust (`winget install
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

meow's normal state, QWERTY layout. You select, then act:

| Select | | Act | | Move | |
| --- | --- | --- | --- | --- | --- |
| `w` `W` word, symbol | | `d` delete (`D` backwards) | | `h j k l` | `H J K L` extend |
| `x` line | | `c` change | | `b` `e` word back / forward | |
| `o` block | | `s` kill, `y` copy, `p` paste | | `f` `t` find / till char | |
| `,` `.` inner / bounds of a thing | | `i` `a` insert / append, `I` `A` open line | | `v` visit, `n` next match | |
| `[` `]` beginning / end of a thing | | `r` replace, `m` join | | `/` search the buffer | |
| `g` cancel selection | | `u` undo, `U` in selection | | `Q` goto line | |

Things after `,` / `.`: `r` round, `s` square, `c` curly, `a` angle, `g` string,
`e` symbol, `p` paragraph, `l` line, `d` defun, `b` buffer.

`SPC` opens the leader tree (which-key shows it); `SPC x` is the `C-x` map.

| | | | |
| --- | --- | --- | --- |
| `SPC SPC` commands | `SPC .` find file | `SPC ,` buffers | `SPC /` ripgrep |
| `SPC b` buffer | `SPC f` file | `SPC p` project | `SPC g` git |
| `SPC w` window | `SPC s` search | `SPC c` code | `SPC o` open |
| `SPC n` notes | `SPC t` toggle | `SPC h` help | `SPC q` quit |
| `SPC k` cursors | `SPC j` jump | `SPC i` insert | `SPC m` **this mode's keys** |

`SPC m` changes with the mode (org, markdown, C, C#, SQL, Verilog ...): look at
it with which-key whenever you are in one.

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
formatter saves again. `SPC t k` turns it off (`(kitty-cat-mode -1)` in
`local.el` to keep it off), and `M-x kitty-cat-paw` calls it whenever you need one.

## The `:` command line

`:` in the normal state is a small vi-style command line.

| | |
| --- | --- |
| `:q` `:qa` | exit Emacs (asks about unsaved buffers); `:q!` exits without asking |
| `:w` `:w file` `:wa` | save, save as, save everything |
| `:wq` `:x` | save this buffer and exit |
| `:e file` `:e!` | open a file, revert the buffer |
| `:bd` `:bn` `:bp` | kill, next, previous buffer |
| `:sp` `:vs` `:only` `:close` | split below / right, keep only this window, close it |
| `:42` | go to line 42 |
| `:%s/a/b/g` `:s/a/b/` | substitute in the buffer / on this line or region (Emacs regexps) |

Anything else is tried as an Emacs command name, so `:magit-status` works.

## Multiple cursors

meow does not copy editor state to a pile of cursors; it records a keyboard
macro and replays it at every position you picked, which stays fast with
thousands. The picking is what these commands do:

| Keys | |
| --- | --- |
| `C` | add a cursor on the next match of the selection (or the symbol at point). Press again for the next. `SPC k p` goes backwards, `SPC k u` drops the last. |
| `M` | cursors on every match in the buffer |
| `SPC k l` | a cursor on every line of the region (`C-u`: keep the column) |
| `SPC k r` | cursors on every regexp match inside the region |
| `<escape>` | leave multiple-cursor mode |

Then edit normally: `c` changes at every cursor, `i` / `a` insert / append at
each, `d` deletes. For anything more, `F3` ... `F4` records a macro and applies
it to all of them. `G` (grab) restricts the cursors to a region first.

## Markdown

`.md` is `gfm-mode`. Prose in a proportional font in a centred column, headings
scaled, tables aligned (valign), code in monospace. Markup (`**`, `#`, backticks,
link targets) is hidden except on the line you are on. Lists, checkboxes and
tables continue as you type; `RET` on a link follows it, on a task toggles it.
Images show inline; `SPC m i p` pastes one from the clipboard into `assets/`.
Code blocks are highlighted in their language, `SPC m e` edits one in its own
buffer. marksman completes and checks links and headings, `SPC m p` previews
live, `SPC m E` exports with pandoc, `SPC m i T` writes a table of contents.
Prettier formats on request only (`SPC c f`), never on save.

## RSS

`SPC o r` opens elfeed and fetches every feed. The feeds are an org file,
`elfeed.org` in `org-directory` (elfeed-org), created with a few examples the
first time; `SPC o R` opens it. One feed link per heading, under a heading
tagged `:elfeed:`; tags are inherited, so feeds under `** Emacs :emacs:` are
tagged `emacs`. Set `kitty-rss-feeds-file` in `local.el` to keep it elsewhere.

In the list: `j` `k` move, `RET` reads, `b` opens in the browser, `s` filters
(`+emacs`, `@1-week-ago`, words), `g` / `G` refresh / fetch, `u` `r` unread /
read, `q` quits and saves. `SPC m` has mark all read, starring and ready-made
filters. Entries are shown wrapped and centred like markdown.

## Languages

| | server | format | `SPC m` |
| --- | --- | --- | --- |
| C / C++ | clangd | clang-format (with a `.clang-format`) | CMake/Ninja or Make, run, ctest, gdb, header/source |
| C# | csharp-ls | the server, on save | `dotnet` build / run / test / watch, add package |
| SQL | sqls (`SPC m L`), sqldiff (flymake) | by dialect, see below | connect, send, describe table, sqldiff (`D` with file, `k` check), `t` dialect |
| Verilog, SystemVerilog | verible | verible | verilator lint, iverilog + vvp, gtkwave, AUTOs, templates |
| Nix | nil | nixfmt | rebuild |

Verilog buffers are also linted by verilator as you type (flymake), for the
checks a language server does not do: widths, unused and undriven signals.

C# needs the .NET SDK: kittymax carries one, a project's dev shell wins.

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

## Why it starts fast

- Garbage collection is off until startup ends, then gcmh keeps it high while
  typing and collects when idle. File-name handlers are off during startup.
- Packages come from Nix: no package.el network, and package-quickstart merges
  all autoloads into one file (rebuilt when the package set changes).
- The Lisp in this directory is byte-compiled into `~/.cache/kittymax/elc` on
  first use (and again when a file changes); Emacs native-compiles it in the
  background after that.
- Everything optional is deferred: modes load with their files, not at startup.
- Rendering and LSP are tuned: `jit-lock` deferral, no bidi scanning, a 4 MB
  process read size, emacs-lsp-booster for JSON, no events buffer, so-long.

`SPC h s` prints what startup cost, module by module.

## When something breaks

A module that fails to load, or a hook function that raises an error, is
reported in `*Warnings*` (`C-h e` shows `*Messages*`) and the rest keeps
working. Emacs itself would stop at the first error: one failing function in a
mode hook switches off syntax highlighting for every buffer of that mode.

## Tests

```sh
kittymax/test/run.sh
```

loads the real meow, markdown-mode and verilog-mode: multiple cursors on a
live meow beacon (every command above, with edits applied), the markdown
reveal-on-current-line behaviour, the verilator flymake backend against a fake
verilator, the loader and keymap helpers, and a smoke test that loads the whole
configuration with no third-party packages at all and checks it degrades
instead of failing.
