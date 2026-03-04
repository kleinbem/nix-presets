{ lib, inv }:
{
  # Generate Homepage configuration
  genHomepageConfig =
    { dashboardNodes }:
    let
      # --- Helper: Icon Matching ---
      # Homepage has many built-in icons (dashboard-icons).
      # We attempt to map our names to their IDs.
      getIcon =
        node:
        let
          lowerName = lib.toLower node.meta.name;
        in
        if lowerName == "caddy proxy" then
          "caddy"
        else if lowerName == "glances" then
          "glances"
        else if lowerName == "ollama" then
          "ollama"
        else if lowerName == "open webui" then
          "ollama" # Use Ollama icon for WebUI too
        else if lowerName == "n8n automation" then
          "n8n"
        else if lowerName == "code server" then
          "visual-studio-code"
        else if lowerName == "cockpit" then
          "cockpit"
        else if lowerName == "miniflux" then
          "miniflux"
        else if lowerName == "cups printing" then
          "cups"
        else if lowerName == "home assistant" then
          "home-assistant"
        else if lowerName == "syncthing" then
          "syncthing"
        else if lowerName == "comfyui" then
          "image"
        else if lowerName == "langflow" then
          "project-diagram"
        else if lowerName == "langfuse" then
          "chart-line"
        else if lowerName == "vllm" then
          "server"
        else if lowerName == "openclaw" then
          "robot"
        else
          "sh-monitor"; # Default generic icon

      # --- Helper: Widget Configuration ---
      # Automatically configure widgets for known services
      getWidget =
        id: node:
        let
          lowerName = lib.toLower node.meta.name;
        in
        if (lowerName == "glances" || lowerName == "sh-monitor") then
          null # Disabled due to v4 compat issue
        else if (lowerName == "n8n automation") then
          {
            type = "n8n";
            url = "https://${node.ip}:${toString node.port}";
            key = "{{HOMEPAGE_VAR_N8N_KEY}}";
          }
        else if (lowerName == "open webui") then
          {
            type = "openwebui";
            url = "http://${node.ip}:${toString node.port}";
            key = "{{HOMEPAGE_VAR_OPENWEBUI_KEY}}";
          }
        else
          null;

      # Determine HREF
      mkHref =
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

      # Create Service Item
      mkItem =
        id: node:
        let
          widgetConfig = getWidget id node;
          href = mkHref node;
        in
        {
          "${node.meta.name}" = (
            {
              icon = getIcon node;
              inherit href;
              description = node.meta.description;
            }
            // lib.optionalAttrs (widgetConfig != null) { widget = widgetConfig; }
            // lib.optionalAttrs (href != "#") { ping = href; }
          );
        };

      # Group items by category
      grouped = lib.groupBy (node: node.meta.category or "Other") (lib.attrValues dashboardNodes);

      catOrder = [
        "Infrastructure"
        "AI Engineering"
        "AI"
        "Apps"
        "Dev"
      ];

      # Create a Homepage group
      mkGroup = cat: nodes: {
        "${cat}" = map (node: mkItem node.meta.name node) nodes;
      };

      # Generate sections in order
      orderedGroups = lib.flatten (
        map (cat: if builtins.hasAttr cat grouped then [ (mkGroup cat grouped.${cat}) ] else [ ]) catOrder
      );

      otherGroups = lib.mapAttrsToList mkGroup (
        lib.filterAttrs (cat: _: !builtins.elem cat catOrder) grouped
      );

    in
    {
      services = orderedGroups ++ otherGroups;

      # Basic Settings
      settings = {
        title = "Homelab";

        layout = [
          # Column 1
          [
            "Infrastructure"
            "System"
          ]
          # Column 2
          [
            "AI Engineering"
            "AI"
          ]
          # Column 3
          [
            "Apps"
            "Development"
            "Automation"
          ]
        ];

        # Custom Background (Unsplash Nature)
        background = {
          image = "https://images.unsplash.com/photo-1506744038136-46273834b3fb?ixlib=rb-4.0.3&auto=format&fit=crop&w=2070&q=80";
          blur = "sm"; # sm, md, lg, xl
          saturate = "50%"; # 0-100%
          brightness = "70%"; # 0-100%
          opacity = "50%"; # 0-100%
        };

        # Network settings
        host = "0.0.0.0"; # Explicitly bind/announce

        # Security
        provider = {
          # weather = "openweathermap";
        };
      };

      # Global Widgets (Top of page)
      widgets = [
        {
          search = {
            provider = "google";
            target = "_blank";
            focus = true; # Focus on load
            show_suggestions = true;
          };
        }
        {
          openmeteo = {
            label = "Watergrasshill";
            latitude = 52.02;
            longitude = -8.34;
            timezone = "Europe/Dublin";
            units = "metric";
          };
        }
        {
          datetime = {
            text_size = "xl";
            format = {
              timeStyle = "short"; # 12:00 PM
              dateStyle = "short"; # 1/1/2024
            };
          };
        }
      ];
    };
}
