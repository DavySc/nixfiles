# my-kak

One Kakoune config for every machine, laid out like [my-nvim](https://github.com/DavySc/my-nvim)
and aiming at the same feel: `<space>` leader, the same groups, the same
languages. Tested on Kakoune 2026.05.21 (what nixpkgs-unstable ships) with `kak-lsp` v22.

## Layout

```
kakrc                    picks the modules, then loads them
lib/core/*.kak           options, ui, keys, clipboard, pane (pickers), git, lsp, format, ai, reload
lib/lang/<name>.kak      one per language: filetype, highlighting, server, formatter, <space>m keys
bin/kak-pane             popups, panes and fzf pickers (tmux, or Kakoune's `terminal`)
bin/kak-clip             system clipboard: Wayland / WSLg, X11, WSL, macOS
colors/                  catppuccin mocha (MIT, from catppuccin/kakoune)
local.example.kak        per-machine settings; copy to local.kak (git-ignored)
flake.nix                kak with every tool the config calls on PATH
tests/run.sh             headless checks against a real kak
```

## Install

Clone to where Kakoune looks:

```sh
git clone git@github.com:DavySc/my-kak ~/.config/kak
```

On NixOS, add the flake to your system flake so `kak` and its tools come together:

```nix
inputs.my-kak = {
  url = "github:DavySc/my-kak";
  inputs.nixpkgs.follows = "nixpkgs";
};
# ...
environment.systemPackages = [ inputs.my-kak.packages.${pkgs.stdenv.hostPlatform.system}.default ];
```

The wrapper puts the tools at the **end** of `PATH`, so a project's dev shell
(its clangd, its rust-analyzer) wins. The config is *not* in the store, it is
read from `~/.config/kak`, so editing and `<space>R` work without a rebuild.
Try it without installing: `nix develop` in a checkout.

Pickers, the Claude pane and the build/run output need **tmux** (or another
environment Kakoune's `terminal` command knows: zellij, kitty, sway, Hyprland,
X11). Without any, those keys say so and everything else works.

## Keys

`<space>` opens the menu (it appears after a moment, which-key style).

| Keys | What | nvim |
| --- | --- | --- |
| `<space>ff` / `fg` / `,` | files / grep / buffers (fzf) | same |
| `<space>e` | explorer (yazi if installed, else the file picker) | snacks explorer |
| `<space>ft` | shell in a popup | float terminal |
| `gd` `gD` `gr` `gI` `gy` | definition, declaration, references, implementation, type | same |
| `<space>k` | hover | `K` (kept: Kakoune's "extend up") |
| `<space>ca` `cf` `cs` `cS` | code action, format, symbols (file, workspace) | `<leader>ca` |
| `<space>rn` | rename | same |
| `<space>xx` `xn` `xp` | diagnostics, next / previous error | trouble |
| `<space>uh` `uw` | inlay hints, soft wrap | `<leader>uh` |
| `<space>gg` `gs` `gl` `gL` `gd` `gb` | lazygit, status, log, log (file), diff, branches | neogit / snacks |
| `<space>hn` `hN` | select next / previous hunk | `]h` `[h` |
| `<space>hs` `hr` `hu` `hS` | stage / reset / unstage the selected lines, stage buffer | gitsigns |
| `<space>hb` `ht` | blame line, blame column | |
| `<space>ac` `aC` | Claude in a side pane, continue last session | claudecode.nvim |
| `<space>p` `P` | paste the system clipboard after / before | `p` (unnamedplus) |
| `<c-n>` | cursor on the word, then on each next match | same |
| `<space>M` | cursor on every match of the word | same |
| `<space>R` | reload the config | same |
| `<space>mm` `mr` `md` `mg` `ma` | build, run, debug, configure, alternate file (C/C++) | same |
| `<space>mm` `mr` | lint (verilator), run (iverilog + vvp) (Verilog) | same |

Yanks and deletes go to the system clipboard on their own (one way); reading
it is `<space>p`. `<backspace>` / `,` is Kakoune's "keep only the main
selection", `#` comments a line.

## Languages

| Language | Server | Format | Notes |
| --- | --- | --- | --- |
| C / C++ | clangd | clang-format (save: only with a `.clang-format`) | single file or CMake project; gdb |
| Verilog / SystemVerilog | verible | verible (on save) | verilator lint, iverilog + vvp run |
| GLSL | glsl_analyzer | clang-format (like C) | C highlighting plus GLSL types |
| Rust | rust-analyzer (via `nix develop` in a flake) | server (rustfmt) on save | |
| Nix | nil | nixfmt on save | |
| Markdown | marksman | prettier, `<space>cf` only | soft wrap |
| Lua | lua-language-server | stylua on save | |

Kakoune has no Verilog or GLSL support of its own: `lib/lang/verilog.kak` and
`glsl.kak` add the filetypes and a small highlighter. `.v` is Verilog (Kakoune
guesses Coq).

## Per machine

`local.kak` (git-ignored) is sourced first. Keep only what the machine changes:
`set-option global langs c nix`, `set-option global transparent false`.

## What is not here

Things nvim has that Kakoune does not, or that are not worth faking:

- **Debugging (DAP).** `<space>md` opens gdb in a pane. No breakpoints UI, no variable view.
- **Tree-sitter.** Kakoune highlights with regexes (good for C, Rust, Nix, Markdown; the Verilog and GLSL ones here are small). `kak-tree-sitter` exists and is the way to get real trees; it is not wired in.
- **Folding, flash.nvim, nvim-spider, render-markdown, indent guides, completion docs popup, snippets beyond what the language server sends.**
- **Claude's IDE protocol** (selection sent as context, edits as diffs). The pane is just `claude`; edits show up through `autoreload`.
- **`]h` / `[h`.** `]` and `[` are Kakoune's object keys; hunks are `<space>hn` / `hN`.
- **Live gitsigns.** The gutter updates on save and reload, not while typing.

Config you can't undo by reloading: a mapping or command you delete stays
until restart. `lib/core/reload.kak` itself needs a restart to change.

## Tests

```sh
tests/run.sh
```

Loads the config in a real `kak -ui dummy` with fake `fzf`, `wl-copy`, `tmux`,
`verilator`, and checks keys, clipboard, format guards, filetypes, the LSP
server tables (valid TOML, ours rather than kak-lsp's defaults), the lint and
build commands, git staging, the pickers against a live session, and reload.
LSP and CMake checks run only when `kak-lsp` and `cmake` are on `PATH`.
