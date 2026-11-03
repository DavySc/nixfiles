{ config, pkgs, ... }:
let
  # Kakoune with the tools my-kak calls. They go at the END of PATH, so a
  # project's dev shell (its own clangd, rust-analyzer ...) wins. Tools that
  # are already in home.packages below (fd, ripgrep, git, nil, nixfmt,
  # lua-language-server, stylua, gcc) are not repeated here.
  kakTools = with pkgs; [
    kakoune-lsp
    fzf
    bat
    lazygit
    tmux # pickers, the Claude pane and popups need a windowing environment
    wl-clipboard # WSLg provides the Wayland socket; kak-clip falls back to clip.exe
    clang-tools # clangd and clang-format
    gdb
    cmake
    ninja
    glsl_analyzer
    verible
    verilator
    iverilog
    marksman
    prettier
  ];

  kak = pkgs.symlinkJoin {
    name = "kak-${pkgs.kakoune-unwrapped.version}-with-tools";
    paths = [ pkgs.kakoune ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/kak --suffix PATH : ${pkgs.lib.makeBinPath kakTools}
    '';
    meta.mainProgram = "kak";
  };
in
{
  home.username = "nixos";
  home.homeDirectory = "/home/nixos";

  # Same rule as the system version: set once, don't change it.
  home.stateVersion = "26.05";

  # Keep the list short. Project-specific toolchains belong in per-project devShells.
  home.packages = with pkgs; [
    neovim
    kak
    ripgrep
    rustc
    cargo
    rustfmt
    clippy
    rust-analyzer
    fd
    postgresql # provides psql
    git
    gcc
    nil
    nixfmt
    lua-language-server
    stylua
    tree-sitter
  ];

  home.sessionVariables.EDITOR = "nvim";
  home.sessionVariables.RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
  home.sessionPath = [ "${config.home.homeDirectory}/.cargo/bin" ];

  programs.git = {
    enable = true;
    settings.user = {
      name = "Davy";
      email = "dvdschoot@pm.me";
    };
  };
  xdg.configFile."nvim".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/my-nvim";
  # Same idea for Kakoune: the config is a checkout at ~/my-kak, read live from
  # ~/.config/kak, so editing it and <space>R needs no rebuild.
  xdg.configFile."kak".source = config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/my-kak";

  programs.home-manager.enable = true;
}
