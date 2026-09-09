# Reads a sources.toml (docs/uptrack.md). URL templates expand like pkgs/up/uptrack/src/pipeline.nu `expand`.
# `unpacker`: store path with bin/{nu,bsdtar} (the seed; nu's `http get` does the download).
# Only the seed's own sources.toml (a .nar) is read without one.
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
  # strip one extension, and a ".tar" before it
  stripExt =
    name:
    let
      m = builtins.match "((.*)\\.tar|(.*))\\.[a-z0-9]+" name;
    in
    if m == null then
      name
    else if builtins.elemAt m 1 != null then
      builtins.elemAt m 1
    else
      builtins.elemAt m 2;
  urlName =
    url:
    let
      base = stripExt url;
      gh = builtins.match "https://github.com/[^/]+/([^/]+)/archive/refs/tags/(.*)" base;
    in
    if gh != null then "${builtins.elemAt gh 0}-${builtins.elemAt gh 1}" else builtins.baseNameOf base;
  fetch =
    key:
    let
      s = byKey.${key};
      url = expand s.url;
      # a fixed-output path is found by (name, hash): with a constant name a bumped url whose
      # hash was not updated silently reuses the old download, so the name follows the url
      name = s.name or (urlName url);
      isNar = builtins.match ".*\\.nar(\\.[a-z0-9]+)?" url != null;
    in
    # `hash` is the NAR hash of what lands in the store: for archives the unpacked tree (single
    # top-level directory stripped, u+w; uptrack's unpack.nu so its hashes agree), fetched and
    # unpacked by one fixed-output derivation running the seed's nu (http get, rustls + built-in
    # roots) and bsdtar, so builds copy a directory instead of decompressing every time.
    # `unpack = false` and .nar urls (the seed itself) go through builtin:fetchurl.
    if !(s.unpack or true) || isNar then
      fetchurl {
        inherit url;
        name = s.name or (builtins.baseNameOf url);
        inherit (s) hash;
        unpack = isNar;
      }
    else
      derivation {
        inherit name system url;
        builder = "${unpacker}/bin/nu";
        args = [
          "--no-config-file"
          ../pkgs/up/uptrack/src/unpack.nu
          "--fetch"
        ];
        inherit unpacker;
        outputHashMode = "recursive";
        outputHash = s.hash;
        preferLocalBuild = true;
        impureEnvVars = [
          "http_proxy"
          "https_proxy"
          "ftp_proxy"
          "all_proxy"
          "no_proxy"
        ];
      };
in
{
  inherit version tag fetch;
  extra = pin.extra or { };
  default = fetch "default";
}
