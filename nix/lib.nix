# Helpers for package.nix and nix/*.nix, injected as `lib` (and `on` on its own, it is everywhere).
# Names say what comes out, one name per idea, data argument last. A function joins this file
# when a third call site wants it; until then it is a `let` where it is used. Not for code that
# runs once per package in nix/package.nix: a call costs thunks an inline `if` does not.
let
  inherit (builtins)
    concatStringsSep
    isAttrs
    isString
    ;
in
rec {
  # `++ on platform.cross [ buildPkgs.x ]`, `// on cond { … }`, `"${on cond "--flag"}"`:
  # the value when the condition holds, else the empty list, set or string of its kind
  on =
    cond: v:
    if cond then
      v
    else if isAttrs v then
      { }
    else if isString v then
      ""
    else
      [ ];
  # space separated is `toString list`
  join = concatStringsSep;
  lines = join "\n";
}
