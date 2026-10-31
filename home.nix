{ config, pkgs, ... }:
{
  home.username = "nixos";
  home.homeDirectory = "/home/nixos";

  # Same rule as the system version: set once, don't change it.
  home.stateVersion = "26.05";

  # Keep the list short. Project-specific toolchains belong in per-project devShells.
  home.packages = with pkgs; [
    neovim
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

  programs.home-manager.enable = true;
}
