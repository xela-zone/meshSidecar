{...}: {
  imports = [
    ./options.nix
    ./bridge.nix
    ./netns.nix
    ./wrappers.nix
    ./providers/tailscale.nix
    ./providers/netbird.nix
    ./integrations/paperless.nix
  ];
}
