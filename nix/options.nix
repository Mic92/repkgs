# repkgs options: every build system's options as { type, default, doc }, plain JSON: `deps`
# defaults (fetcher derivations) become null, package defaults (`tool`) their name
{
  system ? builtins.currentSystem,
}:
{
  options = builtins.mapAttrs (
    _: bs:
    builtins.mapAttrs (
      _: o:
      o
      // {
        default =
          if builtins.elem "set" o.type && builtins.elem "string" o.type then
            null
          else if o.default ? pname then
            "buildPkgs.${o.default.pname}"
          else
            o.default;
      }
    ) bs.options
  ) (import ./set.nix { inherit system; }).buildSystems;
}
