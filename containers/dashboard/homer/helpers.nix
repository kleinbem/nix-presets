{ lib, inv }:
{
  # Process inventory and generate Homer config.yml structure
  genHomerConfig =
    { dashboardNodes }:
    let
      # Determine Link logic (same as custom dashboard)
      mkLink =
        node:
        let
          hasProxy = node ? externalPort;
        in
        if hasProxy then
          (
            if node.externalPort == 443 then
              "https://${inv.hostIP}"
            else
              "https://${inv.hostIP}:${toString node.externalPort}"
          )
        else
          "#";

      # Map a node to a Homer item
      mkItem = _: node: {
        inherit (node.meta) name;
        subtitle = node.meta.description;
        inherit (node.meta) icon; # Homer supports some icons, might need mapping but let's try raw
        url = mkLink node;
      };

      # Group items by category
      grouped = builtins.groupBy (node: node.meta.category or "Other") (lib.attrValues dashboardNodes);

      # Priority for categories
      catOrder = [
        "Infrastructure"
        "AI"
        "Apps"
        "Dev"
      ];

      # Create a Homer group
      mkGroup = cat: nodes: {
        name = cat;
        items = map (node: mkItem node.meta.name node) nodes;
      };

      # Generate sections in order
      orderedGroups = lib.flatten (
        map (cat: if builtins.hasAttr cat grouped then [ (mkGroup cat grouped.${cat}) ] else [ ]) catOrder
      );

      # Catch-all for other categories not in catOrder
      otherGroups = lib.mapAttrsToList mkGroup (
        lib.filterAttrs (cat: _: !builtins.elem cat catOrder) grouped
      );

    in
    {
      title = "Homelab";
      subtitle = "NixOS • Stateless • Secure";
      logo = "logo.png"; # Placeholder
      header = true;
      footer = "<p>NixOS Managed</p>";
      columns = "3";
      connectivityCheck = true;
      services = orderedGroups ++ otherGroups;
    };
}
