# kittymax

An Emacs with my Neovim config's keys, for the jobs Emacs does best (org,
magit, dired, elfeed ...) without retraining my fingers: Neovim
([my-nvim](https://github.com/DavySc/my-nvim)) is the main editor and the
source of truth for every key. evil, catppuccin mocha, built for NixOS, fast to
start, and good at the things I write: org, markdown, C, C++, C#, SQL, Verilog
/ SystemVerilog, Nix.

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
  Windows lacks: `eat` (`SPC t t` opens eshell instead), `jinx` (spell
  checking uses flyspell if aspell/hunspell is on `PATH`), `eglot-booster`.
- **Language servers and tools** that winget has no package for: install
  verible, verilator and iverilog (hardware) and sqls (SQL) yourself and put
  them on `PATH`; kittymax uses what it finds. `SPC t s` (psql) needs the
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
| `C-n` / `SPC M` / `Q` | a cursor on the next match / every match / here; `]C` `[C` between them, `C-l` clears, `gQ` brings them back |
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
`SPC s` search, `SPC n` notes, `SPC t` tools (terminal, eshell, rss, sql,
markdown preview), `SPC i` insert, `SPC q` quit, `SPC H` help, `SPC :` M-x.

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
| C / C++ | clangd | clang-format (with a `.clang-format`) | `m` build, `r` run, `d` gdb, `g` configure, `a` header/source, `T` ctest |
| C# | csharp-ls | the server, on save | `dotnet`: `m` build, `r` run, `t` test, `w` watch, `p` add package |
| SQL | sqls (`SPC m L`), sqldiff (flymake) | by dialect, see below | connect, send, describe table, sqldiff (`D` with file, `k` check), `t` dialect |
| Verilog, SystemVerilog | verible | verible | `m` verilator lint, `r` iverilog + vvp, `w` gtkwave, AUTOs, templates |
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

`SPC H s` prints what startup cost, module by module.

## When something breaks

A module that fails to load, or a hook function that raises an error, is
reported in `*Warnings*` (`C-h e` shows `*Messages*`) and the rest keeps
working. Emacs itself would stop at the first error: one failing function in a
mode hook switches off syntax highlighting for every buffer of that mode.

## Tests

```sh
kittymax/test/run.sh
```

runs inside kittymax's own Emacs (`KITTYMAX_EMACS` for another): every my-nvim
leader key against the command it should run here (`kitty-keys-test.el`, with
nvim-orgmode's and markdown's buffer-only keys, `C-a` and SQL statements), the
markdown reveal-on-current-line behaviour, the verilator flymake backend against a fake
verilator, the loader and keymap helpers, and a smoke test that loads the whole
configuration with no third-party packages at all and checks it degrades
instead of failing.
