{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.meshSidecar;
  meshLib = import ../lib.nix {inherit lib;};

  meshNameMapJSON = builtins.toJSON (meshLib.getMeshNames cfg.services);
  writeDash = pkgs.writers.writeDash;
  concatStringsSep = pkgs.lib.concatStringsSep;
in {
  config = lib.mkIf (cfg.enable && cfg.provider == "netbird") {
    systemd.services."netbird@" = {
      enable = true;
      partOf = ["%i.service"];
      bindsTo = ["netns@%i.service"];
      after = ["netns@%i.service"];
      unitConfig.JoinsNamespaceOf = "netns@%i.service";
      serviceConfig = {
        Type = "simple";
        RemainAfterExit = true;
        LoadCredential =
          if cfg.authKeyFile != null
          then ["auth-key:${cfg.authKeyFile}"]
          else [];
        ExecStart = "${writeDash "netbird-up" ''
          set -x
          MESH_NAME=$(echo '${meshNameMapJSON}' | ${pkgs.jq}/bin/jq -r --arg service "$1" '.[$service] // $service')
          ${pkgs.netbird}/bin/netbird up --foreground-mode --hostname "$MESH_NAME" --setup-key-file "$CREDENTIALS_DIRECTORY/auth-key" --allow-server-ssh
        ''} %i";
        NoNewPrivileges = true;
        PrivateNetwork = true;
        PrivateMounts = true;
        PrivateTmp = true;
        ProtectHome = true;
        PrivateDevices = true;
        ProtectSystem = false;
        ProtectKernelTunables = false;
        ProtectControlGroups = false;
        RuntimeDirectory = "netbird_%i";
        StateDirectory = "netbird_%i";
        ConfigurationDirectory = "netbird_%i";
        BindReadOnlyPaths = concatStringsSep " " [
          "/etc/static:/etc/static"
          "/etc/os-release:/etc/os-release"
          "/etc/pki:/etc/pki"
          "/etc/ssl:/etc/ssl"
        ];
        BindPaths = concatStringsSep " " [
          "/run/netbird_%i:/run/netbird"
          "/var/lib/netbird_%i:/var/lib/netbird"
          "/etc/netbird_%i:/etc/netbird"
          "/etc/netns/%i:/etc"
        ];
      };
    };
  };
}
