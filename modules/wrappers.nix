{
  config,
  lib,
  ...
}: let
  cfg = config.services.meshSidecar;

  providerService =
    if cfg.provider == "netbird"
    then "netbird@%N.service"
    else "tailscale@%N.service";

  serviceOverrides =
    lib.mapAttrs (serviceName: serviceConfig: {
      bindsTo = [providerService];
      after = [providerService];
      unitConfig.JoinsNamespaceOf = providerService;
      # doesn't change based on mesh provider
      serviceConfig.PrivateNetwork = true;
      serviceConfig.BindPaths = ["/etc/netns/%N/resolv.conf:/etc/resolv.conf"];
    })
    cfg.services;
in {
  config = lib.mkIf cfg.enable {
    systemd.services = serviceOverrides;
  };
}
