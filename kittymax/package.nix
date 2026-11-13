# kittymax: Emacs with every package the config uses, plus the language servers
# and tools it calls, as one `kittymax` command.
#
# The Emacs Lisp is NOT in the store: `kittymax` starts Emacs with
# --init-directory pointing at a checkout of this directory (default
# ~/.config/kittymax, see home.nix), so editing a file and restarting (or
# `SPC h r r`) needs no rebuild. Packages and tools do need one.
{
  pkgs,
  configDir ? "$HOME/.config/kittymax",
  # sqldiff (github:DavySc/SQLDiff), from the flake input; without it kittymax
  # builds as before and its sqldiff features stay off.
  sqldiff ? null,
}:
let
  emacsPkg = pkgs.emacs-pgtk; # Wayland/WSLg; native compilation is on by default

  packageList =
    epkgs: with epkgs; [
      # core, performance
      # Vim keys, as in my-nvim (kitty-evil.el, kitty-vim.el)
      evil
      evil-collection
      evil-surround
      evil-mc
      evil-multiedit
      iedit
      evil-args
      evil-lion
      evil-textobj-tree-sitter
      expreg
      undo-fu-session
      no-littering
      gcmh
      puni
      avy
      vundo
      # ui
      catppuccin-theme
      doom-modeline
      nerd-icons
      nerd-icons-completion
      nerd-icons-corfu
      nerd-icons-dired
      rainbow-delimiters
      hl-todo
      helpful
      # completion
      vertico
      orderless
      marginalia
      consult
      consult-eglot
      embark
      embark-consult
      corfu
      cape
      wgrep
      yasnippet
      yasnippet-snippets
      # git
      magit
      transient
      diff-hl
      git-timemachine
      # dired
      dirvish
      diredfl
      # org
      org-modern
      org-appear
      toc-org
      ox-gfm
      org-download
      org-roam # linked notes (SQLite built into Emacs)
      htmlize # code colours in HTML export
      # markdown
      markdown-mode
      markdown-toc
      edit-indirect
      olivetti
      valign
      mixed-pitch
      visual-fill-column
      jinx
      # rss
      elfeed
      elfeed-org
      # programming
      treesit-grammars.with-all-grammars
      treesit-auto
      apheleia
      eglot-booster
      verilog-mode
      sql-indent
      sqlformat
      nix-ts-mode
      eat
      dape # debugging, my-nvim's <leader>d
    ];

  emacsWithPackages = (pkgs.emacsPackagesFor emacsPkg).emacsWithPackages packageList;

  # Put at the END of PATH: a project's dev shell (its clangd, its dotnet) wins.
  tools =
    with pkgs;
    [
      ripgrep
      fd
      git
      delta
      emacs-lsp-booster # eglot-booster: JSON parsing outside Emacs
      # C / C++
      clang-tools # clangd, clang-format
      gdb
      cmake
      ninja
      # C#: csharp-ls needs a .NET SDK; a project's own (nix develop) comes first on PATH
      csharp-ls
      dotnet-sdk
      # SQL
      sqls
      pgformatter
      sqlfluff
      postgresql # psql, for sql-postgres
      # Soufflé (Datalog)
      souffle
      # C# debugging, C / C++ debugging through dape
      netcoredbg
      # Verilog / SystemVerilog
      verible
      verilator
      iverilog
      gtkwave
      # Markdown, org (pandoc: Word export; tectonic + imagemagick: PDF and LaTeX previews)
      marksman
      pandoc
      tectonic
      imagemagick
      prettier
      hunspell
      hunspellDicts.en_US
      enchant
      # Nix
      nil
      nixfmt
    ]
    ++ lib.optional (sqldiff != null) sqldiff; # SQL: lint, cross-dialect diff
in
pkgs.symlinkJoin {
  name = "kittymax-${emacsPkg.version}";
  paths = [ emacsWithPackages ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    # `kittymax [args]`: our config, not ~/.emacs.d. A terminal client: `kittymax -nw`.
    # Emacs silently falls back to its defaults when the init directory is
    # missing, so check for it and say so instead.  KITTYMAX_DIR overrides.
    makeWrapper ${emacsWithPackages}/bin/emacs $out/bin/kittymax \
      --run 'kittymax_dir="''${KITTYMAX_DIR:-${configDir}}"' \
      --run 'if [ ! -f "$kittymax_dir/init.el" ]; then echo "kittymax: no init.el in $kittymax_dir (the ~/.config/kittymax symlink from home.nix is missing: rebuild, or set KITTYMAX_DIR)" >&2; exit 1; fi' \
      --add-flags '--init-directory "$kittymax_dir"' \
      --suffix PATH : ${pkgs.lib.makeBinPath tools} \
      --set KITTYMAX_PACKAGES nix \
      --set-default ENCHANT_PREFIX_DIR ${pkgs.enchant}
  '';
  passthru = {
    inherit emacsWithPackages packageList tools;
  };
  meta.mainProgram = "kittymax";
}
