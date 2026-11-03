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
}:
let
  emacsPkg = pkgs.emacs-pgtk; # Wayland/WSLg; native compilation is on by default

  packageList =
    epkgs: with epkgs; [
      # core, performance
      meow
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
      # markdown
      markdown-mode
      markdown-toc
      edit-indirect
      olivetti
      valign
      mixed-pitch
      visual-fill-column
      jinx
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
    ];

  emacsWithPackages = (pkgs.emacsPackagesFor emacsPkg).emacsWithPackages packageList;

  # Put at the END of PATH: a project's dev shell (its clangd, its dotnet) wins.
  tools = with pkgs; [
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
    # Verilog / SystemVerilog
    verible
    verilator
    iverilog
    gtkwave
    # Markdown, org
    marksman
    pandoc
    prettier
    hunspell
    hunspellDicts.en_US
    enchant
    # Nix
    nil
    nixfmt
  ];
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
