# Reads a sources.toml (docs/uptrack.md). URL templates expand like pkgs/up/uptrack/src/pipeline.nu `expand`.
file:
let
  fetchurl = import <nix/fetchurl.nix>;
  t = builtins.fromTOML (builtins.readFile file);
  pin = t.pin or { };
  version = pin.version or "";
  tag = pin.tag or version;
  mm = builtins.match "([^.]*)\\.?([^.]*).*" version;
  expand =
    builtins.replaceStrings
      [ "{version}" "{version_}" "{major}" "{minor}" "{tag}" ]
      [
        version
        (builtins.replaceStrings [ "." ] [ "_" ] version)
        (builtins.elemAt mm 0)
        (builtins.elemAt mm 1)
        tag
      ];
  byKey = builtins.listToAttrs (
    map (s: {
      name = s.key;
      value = s;
    }) (t.source or [ ])
  );
  fetch =
    key:
    let
      s = byKey.${key};
    in
    fetchurl (
      {
        url = expand s.url;
        inherit (s) hash;
      }
      // (
        if s.unpack or false then
          {
            unpack = true;
            name = s.name or "source";
          }
        else
          { }
      )
    );
in
{
  inherit version tag fetch;
  extra = pin.extra or { };
  default = fetch "default";
}
