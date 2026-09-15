# Helpers for package.nix and nix/*.nix, injected as `lib` (and `on` on its own, it is everywhere).
# Names say what comes out, one name per idea, data argument last. A function joins this file
# when a third call site wants it; until then it is a `let` where it is used. Not for code that
# runs once per package in nix/package.nix: a call costs thunks an inline `if` does not.
let
  inherit (builtins)
    concatStringsSep
    isAttrs
    ;
in
rec {
  # `++ on platform.cross [ buildPkgs.x ]`, `// on cond { … }`: the value when the condition
  # holds, else the empty list or set. Contents stay lazy; not for strings, which have none
  on =
    cond: v:
    if cond then
      v
    else if isAttrs v then
      { }
    else
      [ ];
  # `per platform.os { linux = "linux"; macos = "macosx"; default = null; }`: the entry for
  # `key`, else `default`, else an error naming the key
  per = key: table: table.${key} or table.default or (throw "no entry for ${key}");
  # space separated is `toString list`
  join = concatStringsSep;
  lines = join "\n";
}
