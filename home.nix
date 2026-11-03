{ config, pkgs, ... }:
let
  # Emacs: kittymax, with its packages, language servers and tools (kittymax/).
  # The Lisp is read live from this checkout, see xdg.configFile below.
  kittymax = import ./kittymax/package.nix { inherit pkgs; };
in
{
  home.username = "nixos";
  home.homeDirectory = "/home/nixos";

  # Same rule as the system version: set once, don't change it.
  home.stateVersion = "26.05";

  # Keep the list short. Project-specific toolchains belong in per-project devShells.
  home.packages = with pkgs; [
    neovim
    kittymax
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
    # kittymax: icons and the prose font
    nerd-fonts.jetbrains-mono
    nerd-fonts.symbols-only
    inter
    verible
    clang-tools
    glsl_analyzer
    tmux # Kakoune has no windowing of its own
    marksman # only if you want to test markdown LSP
  ];

  # Make the fonts above visible to Emacs (and everything else) under WSLg.
  fonts.fontconfig.enable = true;

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

  #  xdg.configFile."kak".source =
  #   config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/kak-test";
  # xdg.configFile."kak-lsp".source =
  #  config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/kak-test/lsp";
  xdg.configFile."nvim".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/my-nvim";
<<<<<<< HEAD
  # kittymax's Lisp lives in this repo (kittymax/) and is read live through
  # ~/.config/kittymax: editing it and `SPC h r` needs no rebuild. Packages and
  # tools (kittymax/package.nix) do need one.
  xdg.configFile."kittymax".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nixos-config/kittymax";
=======
  # Same idea for Kakoune: the config lives in this repo (kak/), read live from
  # ~/.config/kak, so editing it and <space>R needs no rebuild.
  xdg.configFile."kak".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nixfiles/kak";
>>>>>>> 7106e36 (bla)

  xdg.configFile."emacs/init.el".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/emacs-test/init.el";
  programs.home-manager.enable = true;
}
