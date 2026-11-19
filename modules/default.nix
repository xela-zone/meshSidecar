{...}: {
  imports = [
    ./options.nix
    ./bridge.nix
    ./netns.nix
    ./wrappers.nix
    ./providers/tailscale.nix
    ./integrations/paperless.nix
  ];
}
