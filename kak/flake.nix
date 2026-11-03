{
  description = "my-kak: Kakoune with the tools my config expects on PATH";

  # Follow your system's nixpkgs from the NixOS flake: inputs.my-kak.inputs.nixpkgs.follows = "nixpkgs";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # Linux only: wl-clipboard and gdb are not available elsewhere.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAll (
        pkgs:
        let
          # What the config calls. Put at the END of PATH, so a project's dev
          # shell (its own clangd, rust-analyzer ...) always wins.
          tools = with pkgs; [
            # lib/core: client, pickers, panes, git, clipboard
            kakoune-lsp
            fzf
            fd
            ripgrep
            bat
            git
            lazygit
            tmux # panes and popups; any Kakoune windowing environment works instead
            wl-clipboard

            # lib/lang/c.kak, glsl.kak
            clang-tools # clangd and clang-format
            gdb
            cmake
            ninja
            glsl_analyzer

            # lib/lang/verilog.kak
            verible
            verilator
            iverilog

            # lib/lang/nix.kak, markdown.kak, lua.kak (rust-analyzer comes from each project's flake)
            nil
            nixfmt
            marksman
            prettier
            lua-language-server
            stylua
          ];
        in
        {
          # `kak` with the tools above on PATH. The config itself is NOT in the
          # store: it is read from ~/.config/kak (a checkout of this repo), so
          # editing it and <space>R works without a rebuild.
          default = pkgs.symlinkJoin {
            name = "kak-${pkgs.kakoune-unwrapped.version}-with-tools";
            paths = [ pkgs.kakoune ];
            nativeBuildInputs = [ pkgs.makeWrapper ];
            postBuild = ''
              wrapProgram $out/bin/kak --suffix PATH : ${pkgs.lib.makeBinPath tools}
            '';
            meta.mainProgram = "kak";
          };
        }
      );

      # nix develop: a shell with kak and the tools, to try the config from a checkout
      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = [ self.packages.${pkgs.stdenv.hostPlatform.system}.default ];
          shellHook = ''export KAKOUNE_CONFIG_DIR="$PWD"'';
        };
      });

      formatter = forAll (pkgs: pkgs.nixfmt);
    };
}
