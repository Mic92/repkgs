# Reads a sources.toml (docs/uptrack.md). URL templates expand like pkgs/up/uptrack/src/pipeline.nu `expand`.
# `unpacker`: store path with bin/{nu,bsdtar} (the seed; nu's `http get` does the download).
# Only the seed's own sources.toml (a .nar) is read without one.
{
  unpacker,
  system ? null,
}:
let
  fetchurl = import <nix/fetchurl.nix>;
  mirrors = import ./mirrors.nix;
  inherit (builtins)
    attrNames
    filter
    concatMap
    substring
    stringLength
    ;
  hasPrefix = p: s: substring 0 (stringLength p) s == p;
  # the url itself, then the same path on every mirror of its prefix (nix/mirrors.nix)
  withMirrors =
    url:
    [ url ]
    ++ concatMap (p: map (m: m + substring (stringLength p) (-1) url) mirrors.${p}) (
      filter (p: hasPrefix p url) (attrNames mirrors)
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
  # `pin`: [pin] keys over the file's, `hashes`: source key -> hash (nix/package.nix, overrides)
  read =
    pin: hashes: file:
    let
      t = builtins.fromTOML (builtins.readFile file);
      pinned = if pin == { } then t.pin or { } else (t.pin or { }) // pin;
      version = pinned.version or "";
      tag = pinned.tag or version;
      mm = builtins.match "([^.]*)\\.?([^.]*).*" version;
      # every [pin] key is a {key} placeholder, plus three spellings derived from the version
      vars = {
        tag = version;
        version_ = builtins.replaceStrings [ "." ] [ "_" ] version;
        major = builtins.elemAt mm 0;
        minor = builtins.elemAt mm 1;
      }
      // pinned;
      expand = builtins.replaceStrings (map (k: "{${k}}") (builtins.attrNames vars)) (
        map toString (builtins.attrValues vars)
      );
      byKey = builtins.listToAttrs (
        map (s: {
          name = s.key;
          value = if hashes ? ${s.key} then s // { hash = hashes.${s.key}; } else s;
        }) (t.source or [ ])
      );
      fetch =
        key:
        let
          s = byKey.${key} or (throw "${toString file}: no source '${key}'");
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
            inherit name system;
            urls = withMirrors url;
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
      has = key: byKey ? ${key};
      default = fetch "default";
      # the same file under another pin (nix/package.nix, for overrides)
      repin = pin: hashes: read pin hashes file;
    };
in
read { } { }
