# meshSidecar

NixOS module providing isolated mesh networking sidecars for systemd services.

## Overview

`meshSidecar` allows existing NixOS systemd services to participate in a mesh network (primarily Tailscale) within dedicated network namespaces. Each service runs in its own network namespace connected via veth pairs to an internal Linux bridge (`meshBridge`), with outbound NAT to the host's default gateway.

This architecture enables:
- Independent mesh identities (distinct hostnames, Tailscale node keys, and IP addresses) per systemd service.
- Isolated network stacks (`PrivateNetwork = true`) so services only access what they need.
- Tailscale Serve and Funnel reverse-proxy capabilities without modifying the target service code.
- Egress-only mesh membership for services needing access to mesh resources without exposing local ports.

---

## Flake Integration

Add `meshSidecar` to your `flake.nix` inputs and import the NixOS module:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    meshSidecar.url = "github:noblepayne/meshSidecar"; # replace with your upstream or fork
  };

  outputs = { self, nixpkgs, meshSidecar, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        meshSidecar.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

---

## Configuration & Usage

### 1. Basic Quickstart (OAuth + Tailscale Serve)

Using dynamic Tailscale OAuth client credentials to automatically provision ephemeral auth keys:

```nix
services.meshSidecar = {
  enable = true;
  provider = "tailscale";

  # Dynamic OAuth key provisioning (recommended)
  oauth = {
    enable = true;
    clientIdFile = "/run/secrets/tailscale-client-id";
    clientSecretFile = "/run/secrets/tailscale-client-secret";
    tags = [ "tag:server" ];
    keyExpirySeconds = 3600;
  };

  # Wrap services into mesh sidecars
  services = {
    grafana = {
      meshName = "monitoring-grafana";
      servePort = 3000; # Proxies https://monitoring-grafana.<tailnet>.ts.net -> 127.0.0.1:3000
    };
  };
};
```

---

## Authentication Methods

### Dynamic OAuth Minting (`oauth.*`)
Instead of managing static reusable or pre-authenticated keys, `meshSidecar` can dynamically mint short-lived auth keys on service startup via the Tailscale API:

```nix
services.meshSidecar.oauth = {
  enable = true;
  clientIdFile = "/run/secrets/tailscale-client-id";
  clientSecretFile = "/run/secrets/tailscale-client-secret";
  tags = [ "tag:server" ]; # ACL tags assigned to the node
  tailnet = "-";            # Defaults to the OAuth client's tailnet
  keyExpirySeconds = 3600;
};
```

> [!IMPORTANT]
> **Tailscale OAuth & ACL Requirements:**
> 1. The OAuth client generated in the Tailscale admin console must have the **`auth_keys`** scope (Auth Keys: write) to create keys via the Tailscale API.
> 2. The OAuth client must have permission to apply the configured tag(s) (e.g. `tag:server`) in your Tailnet ACL policy. If permissions are missing, the API will reject key creation with an HTTP 400 or 403.
> 3. `keyExpirySeconds` sets the lifespan of the *ephemeral registration key* used to register the node, **not** the Tailscale node key itself. Minted nodes are non-ephemeral and persist across system restarts.

### Static Auth Key (`authKeyFile`)
Alternatively, provide a pre-generated auth key passed into the unit via systemd credentials:

```nix
services.meshSidecar.authKeyFile = "/run/secrets/tailscale-authkey";
```

---

## Service Exposure Patterns

Each service in `services.meshSidecar.services.<name>` can be configured with different exposure and proxying behaviors:

> [!NOTE]
> **Service Binding:** `tailscale serve` and `funnel` forward to `127.0.0.1:$TARGET_PORT`. The wrapped service **must listen on `127.0.0.1` or `0.0.0.0`** inside its network namespace. If a service binds strictly to an external IP or a UNIX socket, the reverse proxy cannot reach it.

### Shorthand HTTPS Proxy (`servePort` & `exposeType`)
For services with a single web UI:

```nix
services.meshSidecar.services.vaultwarden = {
  meshName = "vault";
  servePort = 8000;
  exposeType = "serve"; # "serve" (internal tailnet TLS) or "funnel" (public internet via Tailscale Funnel)
};
```

### Granular Port Forwarding (`ports`)
For services requiring multiple ports, plain HTTP, raw TCP streams, or direct socket access:

```nix
services.meshSidecar.services.gitea = {
  meshName = "git";
  ports = [
    {
      port = 443;
      targetPort = 3000;
      type = "serve"; # TLS-terminated HTTPS reverse proxy
    }
    {
      port = 2222;
      targetPort = 22;
      type = "tcp"; # Raw TCP proxying via `tailscale serve --tcp`
    }
    {
      port = 8080;
      type = "passthrough"; # Direct socket listener inside netns, bypassing Tailscale proxy
    }
  ];
};
```

Available port types:
- `"serve"`: TLS-terminated HTTPS reverse proxy via Tailscale Serve.
- `"funnel"`: Publicly accessible TLS-terminated HTTPS reverse proxy via Tailscale Funnel.
- `"http"`: Plain HTTP reverse proxy via Tailscale Serve.
- `"tcp"`: Raw TCP forwarding via `tailscale serve --tcp`.
- `"passthrough"`: Traffic reaches the socket in the namespace directly without Tailscale proxy interception.

### Egress-Only Mode (`exposeType = "client"`)
For background workers or collectors that only need to reach other mesh resources without exposing any local ports:

```nix
services.meshSidecar.services.promtail = {
  exposeType = "client";
  # servePort is optional and omitted
};
```

---

## Advanced Options

### Tailscale Behavior
- `enableSSH` (`bool`, default `false`): By default, Tailscale SSH is disabled inside sidecars. Set to `true` to pass `--ssh` during `tailscale up`.
- `extraUpFlags` (`listOf str`, default `[]`): Extra flags passed directly to `tailscale up` (e.g. `[ "--accept-routes" ]`).
- **State Persistence:** Tailscale states are automatically persisted per service under `/var/lib/ts_mesh/<service>`.

### Network & IP Configuration
- `outboundInterface` (`nullOr str`, default `null`): The host network interface used for outbound NAT. When `null`, it is automatically detected at boot by querying the system's default route.
- `bridgeName` (`str`, default `"meshBridge"`): Name of the host Linux bridge interface (max 15 characters).
- `bridgeCidr` (`str`, default `"192.168.222.1/24"`): Bridge subnet CIDR.
- `dhcpRange` (`listOf str`, default `["192.168.222.2" "192.168.222.254"]`): IP pool managed by internal DHCP (`udhcpd`).
- `nameservers` (`listOf str`): Sidecar DNS resolver list. Defaults to `config.networking.nameservers` if set, otherwise Cloudflare DNS (`["1.1.1.1" "1.0.0.1"]`).
- **Static Hashed IPs (`services.<name>.ip`):** Each service is automatically allocated a deterministic static IP (`192.168.222.<slot>`) derived from a SHA-256 hash of its service name to prevent DHCP exhaustion. Can be overridden manually per service.

---

## Multi-Service Overrides (e.g., Paperless-ngx)

Some complex services (like Paperless) split responsibilities across multiple systemd units (`paperless-web`, `paperless-task-queue`). The `knownServiceOverrides` option wires dependent services into the primary web service's namespace:

```nix
services.paperless.enable = true;

services.meshSidecar = {
  enable = true;
  services.paperless-web = {
    meshName = "paperless";
    servePort = 28981;
  };

  knownServiceOverrides = {
    paperless.enable = true; # Attaches paperless-task-queue to paperless-web's netns
  };
};
```

### Custom Multi-Unit Stacks
If you run other applications that consist of multiple units (for example, a web frontend and a background worker or cron unit), you can manually join auxiliary units into the main service's network namespace:

```nix
systemd.services."my-worker" = {
  serviceConfig.PrivateNetwork = true;
  unitConfig.JoinsNamespaceOf = "netns@my-web.service";
  after = [ "netns@my-web.service" ];
  requires = [ "netns@my-web.service" ];
};
```

---

## Operational Notes & Troubleshooting

### Systemd Unit Architecture
For every wrapped service `<name>`, `meshSidecar` coordinates the following unit dependency chain:
1. `systemdbridge.service`: Initializes the host `meshBridge` interface, sets up NAT, and starts internal DHCP (`udhcpd`).
2. `defaultnetns.service`: Anchors the default network namespace for routing veth pairs.
3. `netns@<name>.service`: Creates the service's network namespace, sets up the veth link (`eth0` <-> bridge), assigns the deterministic static IP, and configures DNS (`/etc/resolv.conf`).
4. `tailscale@<name>.service`: Runs `tailscaled` inside the network namespace, logs into the mesh, and executes `tailscale serve` / `funnel` mappings.
5. `<name>.service`: The target application unit, joined directly into `tailscale@<name>.service`'s network namespace.

### Diagnostic & Inspection Commands

- **Check unit status and journal logs:**
  ```bash
  systemctl status tailscale@<service>.service
  journalctl -u tailscale@<service>.service -e
  ```

- **Inspect Tailscale status & proxy routes directly:**
  Each sidecar runs an isolated `tailscaled` daemon with its socket under `/run/tailscale_<service>/`:
  ```bash
  run0 tailscale --socket /run/tailscale_<service>/tailscaled.sock status
  run0 tailscale --socket /run/tailscale_<service>/tailscaled.sock serve status
  ```

- **Run commands inside the service network namespace:**
  Each namespace is bind-mounted at `/run/meshSidecar_netns/<service>`:
  ```bash
  run0 ip netns exec /run/meshSidecar_netns/<service> ip addr
  run0 ip netns exec /run/meshSidecar_netns/<service> curl -v 127.0.0.1:<targetPort>
  ```

- **State directories:**
  Tailscale persistent node states (identity keys and certificates) are preserved at:
  `/var/lib/ts_mesh/<service>`

---

## Connecting to Host Databases & Services

Because wrapped services run inside isolated network namespaces, `127.0.0.1` inside the namespace is **not** the host's loopback interface. If your service needs to access a database or service running on the host (e.g., PostgreSQL, MariaDB, Redis):

### Option 1: Unix Domain Socket (Recommended)

> [!TIP]
> **Investigate using a UNIX socket file instead of a TCP port:** Network namespaces isolate network interfaces and loopback routing, but filesystem-backed UNIX sockets (e.g., `/run/postgresql/.s.PGSQL.5432`, `/run/mysqld/mysqld.sock`, `/run/redis/redis.sock`) bypass network namespace boundaries completely.

If your application supports socket connections, point its configuration at the host socket path rather than `localhost:<port>`.

*Note:* If the service uses strict systemd filesystem sandboxing (`ProtectSystem = "strict"`), ensure the socket directory is accessible:
```nix
systemd.services.<name>.serviceConfig.BindReadOnlyPaths = [
  "/run/mysqld" # or "/run/postgresql"
];
```

### Option 2: TCP via Bridge Gateway (`192.168.222.1`)

If your database or client library is TCP-only:
1. **Configure the host database to listen on the bridge IP** (or `0.0.0.0`):
   ```nix
   services.mysql.settings.mysqld.bind-address = "0.0.0.0"; # or "127.0.0.1,192.168.222.1"
   # for PostgreSQL: services.postgresql.settings.listen_addresses = lib.mkForce "localhost, 192.168.222.1";
   ```
2. **Allow traffic through the host firewall for `meshBridge`** (the bridge drops host-bound input by default):
   ```nix
   networking.firewall.interfaces."meshBridge".allowedTCPPorts = [ 3306 ]; # or 5432
   ```
3. **Point the application's connection string to the gateway IP:**
   Use `192.168.222.1:<port>` instead of `localhost` or `127.0.0.1`.

---

## Supported Provider

- **Tailscale:** Full native support including dynamic OAuth key minting, Serve (HTTPS / HTTP), Funnel (public TLS), raw TCP forwarding, egress-only (`client`) mode, and persistent state directories (`/var/lib/ts_mesh/<service>`).
*(Note: NetBird support was experimental and has been removed in favor of first-class Tailscale integration).*

---

## License

MIT
