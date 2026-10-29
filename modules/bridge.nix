{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.meshSidecar;
  ip = "${pkgs.iproute2}/bin/ip";
  iptables = "${pkgs.iptables}/bin/iptables";
  udhcpd = "${pkgs.busybox}/bin/udhcpd";
  writeText = pkgs.writeText;
  writeDash = pkgs.writers.writeDash;

  dhcpRouter = builtins.elemAt (builtins.split "/" cfg.bridgeCidr) 0;
  dhcpStart = builtins.elemAt cfg.dhcpRange 0;
  dhcpEnd = builtins.elemAt cfg.dhcpRange 1;
in {
  config = lib.mkIf cfg.enable {
    boot.kernel.sysctl."net.ipv4.ip_forward" = true;

    systemd.services.systemdbridge = {
      before = ["network.target"];
      serviceConfig = {
        Type = "simple";
        RemainAfterExit = true;
        PrivateMounts = true;
        ProtectSystem = "strict";
        RuntimeDirectory = "systemdbridge";
        # N.B. udhcpd writes its lease file to /var/lib/misc
        BindPaths = "/run/systemdbridge:/var/lib/misc";
        ExecStart = "${
          writeDash "${cfg.bridgeName}-up" ''
            set -x
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
            ${iptables} -t nat -A POSTROUTING -o "$OUTBOUND_IF" -j MASQUERADE
            # Allow outbound traffic from our bridge and private services
            ${iptables} -A FORWARD -i ${cfg.bridgeName} -o "$OUTBOUND_IF" -j ACCEPT
            # Allow return traffic
            ${iptables} -A FORWARD -i "$OUTBOUND_IF" -o ${cfg.bridgeName} -m state --state RELATED,ESTABLISHED -j ACCEPT
            ${iptables} -A FORWARD -i "$OUTBOUND_IF" -o ${cfg.bridgeName} -j DROP
            # Allow DHCP (N.B. -I for accept to handle nixos-fw being active)
            ${iptables} -I INPUT -i ${cfg.bridgeName} -p udp --dport 67 -j ACCEPT
            ${iptables} -A INPUT -i ${cfg.bridgeName} -j DROP
            # Clean stale leases on bridge startup to avoid IP exhaustion
            rm -f /run/systemdbridge/udhcpd.leases
            touch /run/systemdbridge/udhcpd.leases
            ${udhcpd} -f -a 0 ${writeText "udhcpd-cfg" ''
              interface ${cfg.bridgeName}
              start ${dhcpStart}
              end ${dhcpEnd}
              option router ${dhcpRouter}
              opt lease 3600
              auto_time 10
            ''}
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
  };
}
