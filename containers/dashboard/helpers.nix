{ lib, inv }:
{
  # Process inventory and generate data structure for the dashboard
  genData =
    { dashboardNodes, hostBridgeIp }:
    let
      # Mapping function to convert NixOS nodes to Dashboard service items
      mkServiceData =
        id: node:
        let
          inherit (node) meta;
          hasProxy = node ? externalPort;
          link =
            if hasProxy then
              (
                if node.externalPort == 443 then
                  "https://${inv.hostIP}"
                else
                  "https://${inv.hostIP}:${toString node.externalPort}"
              )
            else
              "#";
        in
        {
          inherit id link;
          inherit (meta)
            name
            icon
            description
            category
            ;
        };
    in
    {
      inherit hostBridgeIp;
      services = lib.mapAttrsToList (id: node: mkServiceData id node) dashboardNodes;
    };
}
