{ lib, ... }:
{
  options.my.containers.standaloneRunner = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "If true, the host does not evaluate the container's closure and expects it at /var/lib/machines/<name>/current";
  };
}
