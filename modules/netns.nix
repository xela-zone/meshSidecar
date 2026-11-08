{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.meshSidecar;
  ip = "${pkgs.iproute2}/bin/ip";
  mount = "${pkgs.util-linux}/bin/mount";
  umount = "${pkgs.util-linux}/bin/umount";
  udhcpc = "${pkgs.busybox}/bin/udhcpc";
  coreutils = "${pkgs.coreutils}/bin";
  sed = "${pkgs.gnused}/bin/sed";
  writeDash = pkgs.writers.writeDash;
  routerIp = builtins.elemAt (builtins.split "/" cfg.bridgeCidr) 0;
  resolvContent = lib.concatStringsSep "\n" (map (ns: "nameserver ${ns}") cfg.nameservers) + "\n";
  serviceIpCases = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      serviceName: serviceConfig:
        if serviceConfig.ip != null
        then "                  ${serviceName}) SERVICE_IP=\"${serviceConfig.ip}\" ;;"
        else "                  ${serviceName}) SERVICE_IP=\"\" ;;"
    )
    cfg.services
  );
in {
  config = lib.mkIf cfg.enable {
    systemd.services = {
      defaultnetns = {
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
        unitConfig.StopWhenUnneeded = true;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          Restart = "on-failure";
          RestartSec = 2;
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
                                  ETH0_MAC=$(printf "%s" "$1" | ${coreutils}/md5sum | ${sed} 's/^\(..\)\(..\)\(..\)\(..\)\(..\).*/02:\1:\2:\3:\4:\5/')
                                  #${ip} netns add "$1"
                                  #${umount} "/var/run/netns/$1"
                                  mkdir -p /run/meshSidecar_netns
                                  touch "/run/meshSidecar_netns/$1"
                                  ${mount} --bind /proc/self/ns/net "/run/meshSidecar_netns/$1"
                                  ${ip} link add "$VETH_NAME" type veth peer name eth0
                                  ${ip} link set eth0 address "$ETH0_MAC"
                                  ${ip} link set eth0 up
                                  ${ip} link set netns default dev "$VETH_NAME"
                                  ${ip} netns exec default ${ip} link set "$VETH_NAME" master ${cfg.bridgeName}
                                  ${ip} netns exec default ${ip} link set ${cfg.bridgeName} up
                                  ${ip} netns exec default ${ip} link set "$VETH_NAME" up

                                  touch "/etc/netns/$1/resolv.conf"
                                  ${mount} --bind "/etc/netns/$1/resolv.conf" /etc/resolv.conf
                                  cat << 'EOF' > "/etc/netns/$1/resolv.conf"
                  ${resolvContent}EOF

                                  case "$1" in
                ${serviceIpCases}
                                    *) SERVICE_IP="" ;;
                                  esac

                                  if [ -n "$SERVICE_IP" ]; then
                                    IP_ADDR=$(echo "$SERVICE_IP" | ${coreutils}/cut -d/ -f1)
                                    ${ip} addr add "$IP_ADDR/24" dev eth0
                                    ${ip} route add default via ${routerIp} dev eth0
                                  else
                                    ${udhcpc} -f -q -n -t 5 -T 3 -i eth0
                                  fi
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
              ${ip} netns exec default ${ip} link del "$VETH_NAME" || true
              ${umount} "/run/meshSidecar_netns/$1" || true
              rm -f "/run/meshSidecar_netns/$1"

              ${umount} /etc/resolv.conf || true
              # TODO: we can't clean this up easily w/ private mounts. do we care?
              rm -r "/etc/netns/$1" || true
            ''
          } %i";
        };
      };
    };
  };
}
