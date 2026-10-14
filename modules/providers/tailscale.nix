{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.meshSidecar;
  meshLib = import ../lib.nix {inherit lib;};

  meshNameMapJSON = builtins.toJSON (meshLib.getMeshNames cfg.services);
  effectivePortsMapJSON = builtins.toJSON (meshLib.getEffectivePorts cfg.services);
  enableSSHMapJSON = builtins.toJSON (meshLib.getEnableSSH cfg.services);
  extraUpFlagsMapJSON = builtins.toJSON (meshLib.getExtraUpFlags cfg.services);

  writeDash = pkgs.writers.writeDash;
  concatStringsSep = pkgs.lib.concatStringsSep;
in {
  config = lib.mkIf (cfg.enable && cfg.provider == "tailscale") {
    systemd.services."tailscale@" = {
      enable = true;
      partOf = ["%i.service"];
      bindsTo = ["netns@%i.service"];
      after = ["netns@%i.service"];
      unitConfig.JoinsNamespaceOf = "netns@%i.service";
      serviceConfig = {
        Type = "simple";
        RemainAfterExit = true;
        LoadCredential =
          if cfg.oauth.enable
          then [
            "client-id:${cfg.oauth.clientIdFile}"
            "client-secret:${cfg.oauth.clientSecretFile}"
          ]
          else if cfg.authKeyFile != null
          then ["auth-key:${cfg.authKeyFile}"]
          else [];
        ExecStart = "${writeDash "tailscale-up" ''
          set -x
          MESH_NAME=$(echo '${meshNameMapJSON}' | ${pkgs.jq}/bin/jq -r --arg service "$1" '.[$service] // $service')
          PORTS_JSON=$(echo '${effectivePortsMapJSON}' | ${pkgs.jq}/bin/jq -c --arg service "$1" '.[$service] // []')
          ENABLE_SSH=$(echo '${enableSSHMapJSON}' | ${pkgs.jq}/bin/jq -r --arg service "$1" '.[$service] // false')
          EXTRA_FLAGS=$(echo '${extraUpFlagsMapJSON}' | ${pkgs.jq}/bin/jq -r --arg service "$1" '.[$service] // [] | join(" ")')
          TAILSCALE="${pkgs.tailscale}/bin/tailscale -socket $RUNTIME_DIRECTORY/tailscaled.sock"
          # ${pkgs.tailscale}/bin/tailscaled -state 'mem:' &
          ${pkgs.tailscale}/bin/tailscaled -statedir "$STATE_DIRECTORY" -socket "$RUNTIME_DIRECTORY/tailscaled.sock" &

          # Wait for tailscaled socket to be ready and backend state to initialize
          for i in {1..30}; do
            if [ -S "$RUNTIME_DIRECTORY/tailscaled.sock" ]; then
              BACKEND_STATE=$($TAILSCALE status --json 2>/dev/null | ${pkgs.jq}/bin/jq -r '.BackendState // empty')
              if [ -n "$BACKEND_STATE" ] && [ "$BACKEND_STATE" != "NoState" ]; then
                break
              fi
            fi
            sleep 0.5
          done

          IS_LOGGED_IN=false
          if [ "$BACKEND_STATE" = "Running" ] || [ "$BACKEND_STATE" = "Starting" ]; then
            IS_LOGGED_IN=true
          fi

          AUTH_FLAG=""
          if [ "$IS_LOGGED_IN" = "true" ]; then
            AUTH_FLAG=""
          elif [ -n "$CREDENTIALS_DIRECTORY" ] && [ -f "$CREDENTIALS_DIRECTORY/client-id" ] && [ -f "$CREDENTIALS_DIRECTORY/client-secret" ]; then
            CLIENT_ID=$(${pkgs.coreutils}/bin/tr -d '[:space:]' < "$CREDENTIALS_DIRECTORY/client-id")
            CLIENT_SECRET=$(${pkgs.coreutils}/bin/tr -d '[:space:]' < "$CREDENTIALS_DIRECTORY/client-secret")
            TOKEN_RESP=$(${pkgs.curl}/bin/curl -s -f -X POST "https://api.tailscale.com/api/v2/oauth/token" \
              -d "client_id=$CLIENT_ID" \
              -d "client_secret=$CLIENT_SECRET")
            ACCESS_TOKEN=$(echo "$TOKEN_RESP" | ${pkgs.jq}/bin/jq -r '.access_token // empty')
            if [ -z "$ACCESS_TOKEN" ]; then
              echo "Error: Failed to obtain Tailscale OAuth access token" >&2
              exit 1
            fi

            KEY_PAYLOAD=$(${pkgs.jq}/bin/jq -n \
              --arg desc "meshSidecar auto-minted for $1" \
              --argjson tags '${builtins.toJSON cfg.oauth.tags}' \
              --argjson expiry ${toString cfg.oauth.keyExpirySeconds} \
              '{
                capabilities: {
                  devices: {
                    create: {
                      reusable: false,
                      ephemeral: false,
                      tags: $tags,
                      preauthorized: true
                    }
                  }
                },
                expirySeconds: $expiry,
                description: $desc
              }')

            KEY_RESP=$(${pkgs.curl}/bin/curl -s -f -X POST "https://api.tailscale.com/api/v2/tailnet/${cfg.oauth.tailnet}/keys" \
              -H "Authorization: Bearer $ACCESS_TOKEN" \
              -H "Content-Type: application/json" \
              -d "$KEY_PAYLOAD")
            AUTH_KEY=$(echo "$KEY_RESP" | ${pkgs.jq}/bin/jq -r '.key // empty')
            if [ -z "$AUTH_KEY" ]; then
              echo "Error: Failed to obtain Tailscale auth key from API" >&2
              exit 1
            fi
            AUTH_FLAG="--authkey=$AUTH_KEY"
          elif [ -n "$CREDENTIALS_DIRECTORY" ] && [ -f "$CREDENTIALS_DIRECTORY/auth-key" ]; then
            AUTH_FLAG="--authkey=file:$CREDENTIALS_DIRECTORY/auth-key"
          else
            AUTH_FLAG=""
          fi

          SSH_FLAG=""
          if [ "$ENABLE_SSH" = "true" ]; then
            SSH_FLAG="--ssh"
          fi

          ${pkgs.tailscale}/bin/tailscale -socket "$RUNTIME_DIRECTORY/tailscaled.sock" up \
            --reset \
            $SSH_FLAG \
            --accept-dns=true \
            --hostname="$MESH_NAME" \
            $AUTH_FLAG \
            $EXTRA_FLAGS

          echo "$PORTS_JSON" | ${pkgs.jq}/bin/jq -r '.[] | "\(.port) \(.targetPort) \(.type)"' | while read -r PORT TARGET_PORT PORT_TYPE; do
            [ -z "$PORT" ] && continue
            case "$PORT_TYPE" in
              serve|funnel)
                if [ "$PORT" = "443" ]; then
                  $TAILSCALE $PORT_TYPE --bg "http://127.0.0.1:$TARGET_PORT"
                else
                  $TAILSCALE $PORT_TYPE --bg --https="$PORT" "http://127.0.0.1:$TARGET_PORT"
                fi
                ;;
              http)
                $TAILSCALE serve --bg --http="$PORT" "http://127.0.0.1:$TARGET_PORT"
                ;;
              tcp)
                $TAILSCALE serve --bg --tcp="$PORT" "tcp://127.0.0.1:$TARGET_PORT"
                ;;
              passthrough)
                echo "Port $PORT configured as direct netns passthrough (backend target: $TARGET_PORT)"
                ;;
            esac
          done
        ''} %i";
        NoNewPrivileges = true;
        PrivateNetwork = true;
        PrivateMounts = true;
        PrivateTmp = true;
        ProtectHome = true;
        PrivateDevices = false;
        ProtectSystem = false;
        ProtectKernelTunables = false;
        ProtectControlGroups = false;
        RuntimeDirectory = "tailscale_%i";
        StateDirectory = "ts_mesh/%i";
        ConfigurationDirectory = "tailscale_%i";
        TemporaryFileSystem = /etc;
        BindReadOnlyPaths = concatStringsSep " " [
          "/etc/static:/etc/static"
          "/etc/os-release:/etc/os-release"
          "/etc/pki:/etc/pki"
          "/etc/ssl:/etc/ssl"
        ];
        BindPaths = concatStringsSep " " [
          "/run/tailscale_%i:/run/tailscale"
          "/var/lib/ts_mesh/%i:/var/lib/tailscale"
          "/etc/tailscale_%i:/etc/tailscale"
          "/etc/netns/%i/resolv.conf:/etc/resolv.conf"
        ];
        DeviceAllow = ["/dev/net/tun rw"];
        CapabilityBoundingSet = ["CAP_NET_ADMIN" "CAP_SYS_MODULE" "CAP_NET_BIND_SERVICE"];
        AmbientCapabilities = ["CAP_NET_ADMIN" "CAP_SYS_MODULE" "CAP_NET_BIND_SERVICE"];
      };
    };
  };
}
