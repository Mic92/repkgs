# Reads a sources.toml (docs/uptrack.md). URL templates expand like pkgs/up/uptrack/src/pipeline.nu `expand`.
# `unpacker`: store path with bin/nu and bin/bsdtar (the seed), or null where only files are wanted.
{
  unpacker,
  system ? null,
}:
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
  # "llvm-project-21.1.8.src" from …/llvm-project-21.1.8.src.tar.xz, "fd-v10.5.0" for github tag archives
  stripExt =
    name:
    let
      one =
        n:
        if builtins.match "(.*)\\.[a-z0-9]+" n == null then
          n
        else
          builtins.head (builtins.match "(.*)\\.[a-z0-9]+" n);
      once = one name;
    in
    if builtins.match ".*\\.tar" once != null then one once else once;
  urlName =
    url:
    let
      gh = builtins.match "https://github.com/[^/]+/([^/]+)/archive/refs/tags/(.*)" (stripExt url);
    in
    if gh != null then
      "${builtins.elemAt gh 0}-${builtins.elemAt gh 1}"
    else
      stripExt (builtins.baseNameOf url);
  fetch =
    key:
    let
      s = byKey.${key};
      url = expand s.url;
      # a fixed-output path is found by (name, hash): with a constant name a bumped url whose
      # hash was not updated silently reuses the old download, so the name follows the url
      name = s.name or (urlName url);
      file' = fetchurl {
        inherit url;
        name = s.name or (builtins.baseNameOf url);
        inherit (s) hash;
        unpack = builtins.match ".*\\.nar(\\.[a-z0-9]+)?" url != null;
      };
    in
    # archives are unpacked once into their own content-addressed path, so builds copy a store
    # directory instead of decompressing the tarball every time. `unpack = false` keeps the file.
    # (One derivation instead of two once the fetcher itself can run bsdtar.)
    if unpacker == null || !(s.unpack or true) || file'.unpack then
      file'
    else
      derivation {
        inherit name system;
        builder = "${unpacker}/bin/nu";
        args = [
          "--no-config-file"
          "-c"
          "mkdir $env.out; ^$\"($env.unpacker)/bin/bsdtar\" -xf $env.tarball -C $env.out --strip-components 1 --no-same-owner --no-same-permissions; ^$\"($env.unpacker)/bin/chmod\" -R u+w,a-st $env.out"
        ];
        tarball = file';
        inherit unpacker;
        __contentAddressed = true;
        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        preferLocalBuild = true;
        allowedReferences = [ ];
      };
in
{
  inherit version tag fetch;
  extra = pin.extra or { };
  default = fetch "default";
}
