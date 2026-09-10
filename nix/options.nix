# tools/options: every build system's options as { type, default, doc }. `deps` defaults are
# fetcher derivations, elided to null so the result is plain JSON
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
        default = if builtins.elem "set" o.type && builtins.elem "string" o.type then null else o.default;
      }
    ) bs.options
  ) (import ./set.nix { inherit system; }).buildSystems;
}
