{ pkgs, inputs, ... }:
{
  # WSL integration (provided by the NixOS-WSL module).
  # The default user is "nixos"; the module creates that account, so it is not declared here.
  wsl.enable = true;
  wsl.defaultUser = "nixos";

  networking.hostName = "wsl";

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # System-wide tools only. Everything personal goes in home.nix.
  environment.systemPackages = with pkgs; [
    git
  ];

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = { inherit inputs; }; # home.nix: the sqldiff flake
    users.nixos = import ./home.nix;
  };

  # Must match what the existing install already has:
  #   grep stateVersion /etc/nixos/configuration.nix
  # Set once, never change afterwards.
  system.stateVersion = "26.05";
}
