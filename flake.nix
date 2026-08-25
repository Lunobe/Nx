{
  description = "nx — fish CLI for managing a NixOS flake config (build/deploy/update/secrets/packages)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = {...}: {
    homeManagerModules.default = import ./default.nix;
  };
}
