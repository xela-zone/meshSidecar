{
  config,
  lib,
  ...
}: let
  cfg = config.services.meshSidecar;
in {
  config = lib.mkIf (cfg.enable && cfg.knownServiceOverrides.paperless.enable && config.services.paperless.enable) {
    systemd.services = {
      # task-queue is base namespaced joined by other paperless services
      "paperless-task-queue" = {
        # we require private network
        serviceConfig.PrivateNetwork = lib.mkForce true;
        # TODO: Could add to all services if we want full mesh participation
        # TODO: make this easy but w/ only one mesh vpn per pod?
        serviceConfig.BindPaths = ["/etc/netns/paperless-web/resolv.conf:/etc/resolv.conf"];

        # wait until our base namespace is configured
        after = lib.mkAfter ["netns@paperless-web.service"];
        # force all paperless services using task-queue's namespace to use ours
        unitConfig.JoinsNamespaceOf = lib.mkForce "netns@paperless-web.service";
      };
      # override paperless-web values to clear conflicts.
      "paperless-web" = {
        # we require private network
        serviceConfig.PrivateNetwork = lib.mkForce true;
        # this could be our netns or task-queue now that they are the same
        unitConfig.JoinsNamespaceOf = lib.mkForce "paperless-task-queue.service";
      };
    };
  };
}
