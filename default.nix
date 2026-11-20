{...}: {
  imports = [
    ./helpers-ui-git.nix
    ./helpers-config.nix
    ./cmd-deploy.nix
    ./cmd-format.nix
    ./cmd-maintenance.nix
    ./cmd-nuke-history.nix
    ./cmd-packages.nix
    ./cmd-secret-search-config.nix
    ./cmd-vm.nix
    ./dispatcher.nix
  ];
}
