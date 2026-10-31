{
  description = "Davy's NixOS-WSL prototype";

  inputs = {
    # Track unstable for the prototype. Pin a release branch later once the setup settles.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixos-wsl.url = "github:nix-community/NixOS-WSL";
    nixos-wsl.inputs.nixpkgs.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    neovim-nightly-overlay.url = "github:nix-community/neovim-nightly-overlay";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-wsl,
      home-manager,
      neovim-nightly-overlay,
      ...
    }:
    {
      # The attribute name ("wsl") is what you pass to nixos-rebuild: --flake .#wsl
      nixosConfigurations.wsl = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          nixos-wsl.nixosModules.default
          home-manager.nixosModules.home-manager
          { nixpkgs.overlays = [ neovim-nightly-overlay.overlays.default ]; }
          ./configuration.nix
        ];
      };
    };
}
