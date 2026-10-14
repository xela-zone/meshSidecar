{
  config,
  options,
  pkgs,
  lib,
  ...
}: {
  options.services.meshSidecar = {
    enable = lib.mkEnableOption "meshSidecar module";

    provider = lib.mkOption {
      type = lib.types.enum ["tailscale" "netbird"];
      description = ''Mesh network service provider e.g. currently "tailscale" or "netbird".'';
      default = "tailscale";
    };

    # TODO: support providing multiple, tied to service. support multiple mesh providers at once?
    authKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to key file for mesh provider auth.";
    };

    oauth = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable automatic OAuth client token exchange to dynamically mint Tailscale auth keys.";
      };
      clientIdFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to file containing Tailscale OAuth Client ID.";
      };
      clientSecretFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to file containing Tailscale OAuth Client Secret.";
      };
      tags = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["tag:server"];
        description = "Tags to assign to minted auth keys.";
      };
      tailnet = lib.mkOption {
        type = lib.types.str;
        default = "-";
        description = "Tailnet identifier to create auth keys in ('-' defaults to current tailnet of OAuth token).";
      };
      keyExpirySeconds = lib.mkOption {
        type = lib.types.int;
        default = 3600;
        description = "Lifetime in seconds of minted auth keys (default 1 hour).";
      };
    };

    outboundInterface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Name of the outbound network interface. If not set, it will be autodetected at runtime.";
    };

    bridgeName = lib.mkOption {
      type = lib.types.addCheck lib.types.str (
        name:
          builtins.stringLength name <= 15 && name != ""
      );
      description = "Name of the bridge interface.";
      default = "meshBridge";
    };

    bridgeCidr = lib.mkOption {
      type = lib.types.str;
      description = "Bridge IP address and subnet in CIDR notation (e.g., 192.168.222.1/24).";
      default = "192.168.222.1/24";
    };

    dhcpRange = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      description = ''
        DHCP range as a two-element list of IP addresses, e.g. [ "192.168.222.2" "192.168.222.254" ].
      '';
      # TODO: split into two options? test/assert its length two?
      default = ["192.168.222.2" "192.168.222.254"];
    };

    #upstreamDns = lib.mkOption {
    #  type = lib.types.listOf lib.types.str;
    #  description = ''
    #    List of upstream DNS server IP addresses to use for DNS resolution.
    #    Example: [ "8.8.8.8" "1.1.1.1" ]
    #  '';
    #  default = ["1.1.1.1" "8.8.8.8"];
    #};

    services = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          meshName = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Hostname to use on the mesh network. Defaults to service name.";
          };
          servePort = lib.mkOption {
            type = lib.types.nullOr lib.types.port;
            default = null;
            description = "Local port to proxy (remaps 443 -> servePort internally). Not required for exposeType 'client'.";
          };
          exposeType = lib.mkOption {
            type = lib.types.enum ["serve" "funnel" "client"];
            default = "serve";
            description = "How to expose the service: 'serve' (tailnet only), 'funnel' (public), or 'client' (egress-only, joins mesh without serving anything).";
          };
          enableSSH = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether to pass --ssh to tailscale up. Defaults to false (sidecars do not need Tailscale SSH).";
          };
          extraUpFlags = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Additional flags to pass to tailscale up.";
          };
          ports = lib.mkOption {
            type = lib.types.listOf (lib.types.submodule {
              options = {
                port = lib.mkOption {
                  type = lib.types.port;
                  description = "External port on the mesh node.";
                };
                targetPort = lib.mkOption {
                  type = lib.types.nullOr lib.types.port;
                  default = null;
                  description = "Internal backend port on 127.0.0.1. Defaults to the same value as 'port'.";
                };
                type = lib.mkOption {
                  type = lib.types.enum [ "serve" "funnel" "http" "tcp" "passthrough" ];
                  default = "serve";
                  description = ''
                    How to expose the port:
                    - 'serve': TLS-terminated HTTPS reverse proxy via Tailscale Serve (autogen certs).
                    - 'funnel': Publicly accessible TLS-terminated HTTPS reverse proxy via Tailscale Funnel.
                    - 'http': Unencrypted HTTP reverse proxy via Tailscale Serve.
                    - 'tcp': Raw TCP packet forwarding via Tailscale Serve (--tcp).
                    - 'passthrough': Direct listener in the network namespace (no Tailscale proxy, traffic routes directly to local socket).
                  '';
                };
              };
            });
            default = [];
            description = "Collection of ports to expose or pass through for this service.";
          };
        };
      });
      default = {};
      description = "Services to wrap with mesh networking";
    };

    knownServiceOverrides = lib.mkOption {
      type = lib.types.submodule {
        options = {
          paperless.enable = lib.mkEnableOption "Apply paperless-specific overrides";
        };
      };
      default = {};
      description = "Enable known service integration overrides";
    };
  };

  config = let
    # Grab our module config
    cfg = config.services.meshSidecar;
    # Bind required bins
    ip = "${pkgs.iproute2}/bin/ip";
    iptables = "${pkgs.iptables}/bin/iptables";
    mount = "${pkgs.util-linux}/bin/mount";
    umount = "${pkgs.util-linux}/bin/umount";
    udhcpd = "${pkgs.busybox}/bin/udhcpd";
    udhcpc = "${pkgs.busybox}/bin/udhcpc";
    # Bind required libs
    writeText = pkgs.writeText;
    writeDash = pkgs.writers.writeDash;
    concatStringsSep = pkgs.lib.concatStringsSep;
    # Derived config data
    dhcpRouter = builtins.elemAt (builtins.split "/" cfg.bridgeCidr) 0;
    dhcpStart = builtins.elemAt cfg.dhcpRange 0;
    dhcpEnd = builtins.elemAt cfg.dhcpRange 1;
    # TODO: method to support more than two providers cleanly
    serviceOverrides =
      lib.mapAttrs (serviceName: serviceConfig: {
        bindsTo =
          if cfg.provider == "netbird"
          then ["netbird@%N.service"]
          else ["tailscale@%N.service"];
        after =
          if cfg.provider == "netbird"
          then ["netbird@%N.service"]
          else ["tailscale@%N.service"];
        unitConfig.JoinsNamespaceOf =
          if cfg.provider == "netbird"
          then "netbird@%N.service"
          else "tailscale@%N.service";
        # doesn't change based on mesh provider
        serviceConfig.PrivateNetwork = true;
        serviceConfig.BindPaths = ["/etc/netns/%N/resolv.conf:/etc/resolv.conf"];
      })
      cfg.services;
    meshNameMap = lib.mapAttrs (k: v:
      if v.meshName != null
      then v.meshName
      else k)
    cfg.services;
    meshNameMapJSON = builtins.toJSON meshNameMap;
    effectivePortsMap = lib.mapAttrs (_: service:
      let
        explicitPorts = service.ports;
        has443 = builtins.any (p: p.port == 443) explicitPorts;
        legacyPort = lib.optional (service.servePort != null && service.exposeType != "client" && !has443) {
          port = 443;
          targetPort = service.servePort;
          type = service.exposeType;
        };
        combined = explicitPorts ++ legacyPort;
      in
        map (p: {
          port = p.port;
          targetPort = if p.targetPort != null then p.targetPort else p.port;
          type = p.type;
        }) combined
    ) cfg.services;
    effectivePortsMapJSON = builtins.toJSON effectivePortsMap;
    enableSSHMap = lib.mapAttrs (_: v: v.enableSSH) cfg.services;
    enableSSHMapJSON = builtins.toJSON enableSSHMap;
    extraUpFlagsMap = lib.mapAttrs (_: v: v.extraUpFlags) cfg.services;
    extraUpFlagsMapJSON = builtins.toJSON extraUpFlagsMap;
    moduleServices = {
      "systemdbridge" = {
        before = ["network.target"];
        serviceConfig = {
          Type = "simple";
          RemainAfterExit = true;
          PrivateMounts = true;
          ProtectSystem = "strict";
          RuntimeDirectory = "systemdbridge";
          # N.B. udhcpd writes it's lease file to /var/lib/misc
          BindPaths = "/run/systemdbridge:/var/lib/misc";
          # TODO: configurable outbound interface or autodiscovery?
          ExecStart = "${
            writeDash "${cfg.bridgeName}-up" ''
              set -x
              # TODO: export needed?
              export PATH=${pkgs.busybox}/bin

              OUTBOUND_IF="${
                if cfg.outboundInterface != null
                then cfg.outboundInterface
                else ""
              }"
              if [ -z "$OUTBOUND_IF" ]; then
                echo "Outbound interface not specified, attempting autodetection..." >&2
                i=0
                while [ $i -lt 30 ]; do
                  OUTBOUND_IF=$(${ip} route show | grep default | awk '{print $5}' | head -n1)
                  if [ -n "$OUTBOUND_IF" ]; then
                    break
                  fi
                  sleep 1
                  i=$((i + 1))
                done
              fi
              if [ -z "$OUTBOUND_IF" ]; then
                echo "Error: Could not autodetect outbound interface." >&2
                exit 1
              fi

              ${ip} link add ${cfg.bridgeName} type bridge
              ${ip} addr add ${cfg.bridgeCidr} dev ${cfg.bridgeName}
              ${ip} link set ${cfg.bridgeName} up
              # Enable NAT
              # TODO: add -s (e.g. 192.168.222.0/24, may need cfg changes for how we pass this info)
              ${iptables} -t nat -A POSTROUTING -o "$OUTBOUND_IF" -j MASQUERADE
              # Allow outbound traffic from our bridge and private services
              ${iptables} -A FORWARD -i ${cfg.bridgeName} -o "$OUTBOUND_IF" -j ACCEPT
              # Allow return traffic
              ${iptables} -A FORWARD -i "$OUTBOUND_IF" -o ${cfg.bridgeName} -m state --state RELATED,ESTABLISHED -j ACCEPT
              ${iptables} -A FORWARD -i "$OUTBOUND_IF" -o ${cfg.bridgeName} -j DROP
              # Allow DHCP (N.B. -I for accept to handle nixos-fw being active)
              ${iptables} -I INPUT -i ${cfg.bridgeName} -p udp --dport 67 -j ACCEPT
              ${iptables} -A INPUT -i ${cfg.bridgeName} -j DROP
              #${udhcpd} -f ${writeText "udhcpd-cfg" "interface ${cfg.bridgeName}\nstart ${dhcpStart}\nend ${dhcpEnd}\noption router ${dhcpRouter}\noption dns 1.1.1.1\n"}
              ${udhcpd} -f ${writeText "udhcpd-cfg" "interface ${cfg.bridgeName}\nstart ${dhcpStart}\nend ${dhcpEnd}\noption router ${dhcpRouter}\n"}
            ''
          }";
          ExecStop = "${
            writeDash "${cfg.bridgeName}-down" ''
              set -x

              OUTBOUND_IF="${
                if cfg.outboundInterface != null
                then cfg.outboundInterface
                else ""
              }"
              if [ -z "$OUTBOUND_IF" ]; then
                OUTBOUND_IF=$(${ip} route show | grep default | awk '{print $5}' | head -n1)
              fi

              # Delete bridge
              ${ip} link del ${cfg.bridgeName}
              # Cleanup leftover iptables rules
              if [ -n "$OUTBOUND_IF" ]; then
                ${iptables} -t nat -D POSTROUTING -o "$OUTBOUND_IF" -j MASQUERADE
                ${iptables} -D FORWARD -i ${cfg.bridgeName} -o "$OUTBOUND_IF" -j ACCEPT
                ${iptables} -D FORWARD -i "$OUTBOUND_IF" -o ${cfg.bridgeName} -m state --state RELATED,ESTABLISHED -j ACCEPT
                ${iptables} -D FORWARD -i "$OUTBOUND_IF" -o ${cfg.bridgeName} -j DROP
              fi
              ${iptables} -D INPUT -i ${cfg.bridgeName} -p udp --dport 67 -j ACCEPT
              ${iptables} -D INPUT -i ${cfg.bridgeName} -j DROP
            ''
          }";
        };
      };

      "defaultnetns" = {
        before = ["network.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStop = "${ip} netns del default";
          ExecStart = "${
            writeDash "defaultnetns-up" ''
              set -x
              ${ip} netns add default
              ${umount} /var/run/netns/default
              ${mount} --bind /proc/1/ns/net /var/run/netns/default
            ''
          }";
        };
      };

      "netns@" = {
        description = "%i network namespace";
        partOf = ["netbird@%i.service" "tailscale@%i.service"];
        bindsTo = ["systemdbridge.service" "defaultnetns.service"];
        after = ["systemdbridge.service" "defaultnetns.service"];
        before = ["network.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          PrivateNetwork = true;
          ConfigurationDirectory = "netns/%i";
          PrivateMounts = false; # TODO...
          # TODO: make per-service configurable
          PrivateTmp = true;
          ExecStart = "${
            writeDash "netns-up" (''
                set -x
                # Linux interface name max is 15 char
                VETH_NAME=$(printf "%.15s" "$1")
                #${ip} netns add "$1"
                #${umount} "/var/run/netns/$1"
                mkdir -p /run/meshSidecar_netns
                touch "/run/meshSidecar_netns/$1"
                ${mount} --bind /proc/self/ns/net "/run/meshSidecar_netns/$1"
                ${ip} link add "$VETH_NAME" type veth peer name eth0
                ${ip} link set eth0 up
                ${ip} link set netns default dev "$VETH_NAME"
                ${ip} netns exec default ${ip} link set "$VETH_NAME" master ${cfg.bridgeName}
                ${ip} netns exec default ${ip} link set ${cfg.bridgeName} up
                ${ip} netns exec default ${ip} link set "$VETH_NAME" up

                #${ip} netns exec default cat /etc/nsswitch.conf > "/etc/netns/$1/nsswitch.conf"
                #echo 'hosts: dns' > "/etc/netns/$1/nsswitch.conf"

                touch "/etc/netns/$1/resolv.conf"
                # TODO: to replace ip netns exec
                mount --bind "/etc/netns/$1/resolv.conf" /etc/resolv.conf
                #${ip} netns exec "$1" ${udhcpc} -f -q -n -t 3 -T 3 -i eth0
                ${udhcpc} -f -q -n -t 3 -T 3 -i eth0
                # TODO: patch udhcpc to only overwrite when dns option is present
                # until then, we just overwrite after it runs
                # TODO: needs magic dns if we want tailscale to manage, if non-empty.
                # leaving empty for now as this does not break tailscale
                #${ip} netns exec default cat /etc/resolv.conf > "/etc/netns/$1/resolv.conf"
                #cat "/etc/netns/$1/resolv.conf"
              ''
              + (
                if cfg.provider == "netbird"
                then "\n${ip} netns exec default cat /etc/resolv.conf > /etc/netns/\"$1\"/resolv.conf\n"
                else ""
              ))
          } %i";
          ExecStopPost = "${
            writeDash "netns-down" ''
              set -x
              # Linux interface name max is 15 char
              VETH_NAME=$(printf "%.15s" "$1")
              ${ip} netns exec default ${ip} link del "$VETH_NAME"
              ${umount} "/run/meshSidecar_netns/$1"
              rm "/run/meshSidecar_netns/$1"
              #${ip} netns del "$1"

              umount /etc/resolv.conf
              # TODO: we can't clean this up easily w/ private mounts. do we care?
              rm -r "/etc/netns/$1" || true
            ''
          } %i";
        };
      };

      "netbird@" = {
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
          #PrivateUsers=true;  # Needs to be root for network stuff, but can we grant these privs another way?
          PrivateNetwork = true;
          PrivateMounts = true;
          PrivateTmp = true;
          ProtectHome = true;
          PrivateDevices = true;
          # netbird does routing things?
          ProtectSystem = false;
          ProtectKernelTunables = false;
          ProtectControlGroups = false;
          # Places to keep things
          RuntimeDirectory = "netbird_%i";
          StateDirectory = "netbird_%i";
          ConfigurationDirectory = "netbird_%i";
          BindReadOnlyPaths = concatStringsSep " " [
            # required by netbird?
            "/etc/static:/etc/static"
            "/etc/os-release:/etc/os-release"
            # maybe not required along with static?
            "/etc/pki:/etc/pki"
            "/etc/ssl:/etc/ssl"
          ];
          BindPaths = concatStringsSep " " [
            # use netbird_%i instead of netbird for storage
            "/run/netbird_%i:/run/netbird"
            "/var/lib/netbird_%i:/var/lib/netbird"
            "/etc/netbird_%i:/etc/netbird"
            # network namespace (for resolv etc, and to further isolate)
            "/etc/netns/%i:/etc"
          ];
        };
      };

      "tailscale@" = {
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

            # Wait for tailscaled socket to be ready
            for i in {1..20}; do
              if [ -S "$RUNTIME_DIRECTORY/tailscaled.sock" ]; then
                break
              fi
              sleep 0.5
            done

            IS_LOGGED_IN=false
            BACKEND_STATE=$(${pkgs.tailscale}/bin/tailscale -socket "$RUNTIME_DIRECTORY/tailscaled.sock" status --json 2>/dev/null | ${pkgs.jq}/bin/jq -r '.BackendState // empty')
            if [ "$BACKEND_STATE" = "Running" ]; then
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
          # PrivateUsers = true; # Needs to be root for network stuff, but can we grant these privs another way?
          PrivateNetwork = true;
          PrivateMounts = true;
          PrivateTmp = true;
          ProtectHome = true;
          PrivateDevices = false; #true
          # tailscale does routing things?
          ProtectSystem = false;
          ProtectKernelTunables = false;
          ProtectControlGroups = false;
          # Places to keep things
          RuntimeDirectory = "tailscale_%i";
          StateDirectory = "ts_mesh/%i";
          ConfigurationDirectory = "tailscale_%i";
          TemporaryFileSystem = /etc;
          BindReadOnlyPaths = concatStringsSep " " [
            # required by tailscale?
            "/etc/static:/etc/static"
            "/etc/os-release:/etc/os-release"
            # maybe not required along with static?
            "/etc/pki:/etc/pki"
            "/etc/ssl:/etc/ssl"
          ];
          BindPaths = concatStringsSep " " [
            # use tailscale_%i instead of netbird for storage
            "/run/tailscale_%i:/run/tailscale"
            "/var/lib/ts_mesh/%i:/var/lib/tailscale"
            "/etc/tailscale_%i:/etc/tailscale"
            # network namespace (for resolv etc, and to further isolate)
            "/etc/netns/%i/resolv.conf:/etc/resolv.conf"
          ];
          DeviceAllow = ["/dev/net/tun rw"];
          # Give only the needed capability
          CapabilityBoundingSet = ["CAP_NET_ADMIN" "CAP_SYS_MODULE" "CAP_NET_BIND_SERVICE"];
          AmbientCapabilities = ["CAP_NET_ADMIN" "CAP_SYS_MODULE" "CAP_NET_BIND_SERVICE"];
        };
      };
    };
  in
    lib.mkMerge [
      (lib.mkIf cfg.enable {
        boot.kernel.sysctl."net.ipv4.ip_forward" = true;
        systemd.services = moduleServices // serviceOverrides;
      })
      # Overrides
      # paperless
      (lib.mkIf (cfg.enable && cfg.knownServiceOverrides.paperless.enable && config.services.paperless.enable) {
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
      })
    ];
}
