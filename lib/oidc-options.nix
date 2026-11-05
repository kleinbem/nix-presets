# oidc-options.nix — Reusable Authentik OIDC option submodule for container presets.
# Import this in any container module that supports native Authentik SSO (Option A).
{
  lib,
  defaultName ? "",
}:
{
  oidc = {
    enable = lib.mkEnableOption "Authentik OIDC SSO integration for ${defaultName}";
    clientId = lib.mkOption {
      type = lib.types.str;
      default = defaultName;
      description = "OAuth2 Client ID registered with Authentik";
    };
    issuerUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://auth.kleinbem.dev/application/o/${defaultName}/.well-known/openid-configuration";
      description = "OpenID Connect discovery endpoint URL";
    };
    scopes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "openid"
        "email"
        "profile"
      ];
      description = "OAuth scopes to request from Authentik";
    };
  };
}
