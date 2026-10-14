{lib}: {
  getEffectivePorts = services:
    lib.mapAttrs (_: service:
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
          targetPort =
            if p.targetPort != null
            then p.targetPort
            else p.port;
          type = p.type;
        })
        combined)
    services;

  getMeshNames = services:
    lib.mapAttrs (k: v:
      if v.meshName != null
      then v.meshName
      else k)
    services;

  getEnableSSH = services: lib.mapAttrs (_: v: v.enableSSH) services;

  getExtraUpFlags = services: lib.mapAttrs (_: v: v.extraUpFlags) services;
}
