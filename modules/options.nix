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
                  type = lib.types.enum ["serve" "funnel" "http" "tcp" "passthrough"];
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
}
