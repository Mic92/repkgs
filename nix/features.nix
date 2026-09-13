# A package's `features`: knobs its package.nix declares and reads back as values.
#
#   features = {
#     tls = { values = [ "openssl" "gnutls" "none" ]; default = "openssl"; doc = "TLS backend"; };
#     http3 = { default = false; };
#     codecs = { default = [ "opus" ]; doc = "…"; };
#   };
#   dependencies = on (features.tls != "none") [ pkgs.${features.tls} ];
#
# The type is the default's (bool, string, list, int), `values` limits a string or a list's
# elements to a set. Resolved
# once per package as default <- set-wide `features` argument (only names the package declares)
# <- `overrides.<pkg>.features`. A name the package does not declare or a value of another type
# is an error. The result is in the derivation (drv hash) and on it as `.features`.
let
  inherit (builtins)
    all
    attrNames
    elem
    isList
    intersectAttrs
    mapAttrs
    typeOf
    ;
  check =
    pkg: decl: given:
    mapAttrs (
      n: v:
      let
        d = decl.${n};
      in
      if typeOf v != typeOf d.default then
        throw "${pkg}: feature ${n} wants a ${typeOf d.default}, got a ${typeOf v}"
      else if d ? values && !(all (x: elem x d.values) (if isList v then v else [ v ])) then
        throw "${pkg}: feature ${n} = ${toString v}, not among ${toString d.values}"
      else
        v
    ) given;
in
{
  # decl: the package's `features` field ({} when absent). global: the set's. local: overrides.<pkg>.features
  resolve =
    pkg: decl: global: local:
    let
      defaults = mapAttrs (_: d: d.default) decl;
      g = intersectAttrs decl global;
      unknown = attrNames (removeAttrs local (attrNames decl));
    in
    if decl == { } && local == { } then
      { }
    else if unknown != [ ] then
      throw "${pkg}: unknown features ${toString unknown} (has: ${toString (attrNames decl)})"
    else
      defaults // check pkg decl g // check pkg decl local;
}
