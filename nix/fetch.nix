# Dependency fetchers. Upstream tarballs themselves come from sources.toml (nix/sources.nix).
# cargoVendor emits per-crate fetchurl derivations at build time (dynamic derivations, no hash of
# ours). goModules is still a fixed-output `go mod vendor` (go.sum hashes are not tarball hashes).
{ tools, nu }:
let
  system = builtins.currentSystem;

  # A dynamic derivation: `script` (under builder-rpc-v0, with `jig nix-store`) writes the real
  # derivation into the store and submits its .drv as the output. Callers get that drv's "out".
  dynamic =
    name: script: env:
    let
      producer = derivation (
        {
          name = "${name}.drv";
          inherit system;
          seed = nu;
          builder = "${nu}/bin/nu";
          args = [ script ];
          PATH = "${tools.jig}/bin:${nu}/bin";
          requiredSystemFeatures = [ "builder-rpc-v0" ];
          preferLocalBuild = true;
          __contentAddressed = true;
          outputHashMode = "text";
          outputHashAlgo = "sha256";
        }
        // env
      );
    in
    builtins.outputOf producer.outPath "out";

  vendor =
    {
      name,
      hash,
      path,
      script,
      env ? { },
    }:
    derivation (
      {
        inherit name system;
        builder = "${nu}/bin/nu";
        args = [
          "-c"
          script
        ];
        PATH = builtins.concatStringsSep ":" (map (p: "${p}/bin") (path ++ [ nu ]));
        SSL_CERT_FILE = "${tools.cacert}/etc/ssl/certs/ca-bundle.crt";
        outputHashMode = "recursive";
        outputHashAlgo = "sha256";
        outputHash = hash;
        preferLocalBuild = true;
      }
      // env
    );
in
{
  # Registry crates from the Cargo.lock *inside* `source`, as a directory cargo accepts under
  # [source.vendored]. No hash argument and no checked-in lock file: a small producer derivation
  # (builder-rpc-v0, see builder/fetch-cargo.nu) reads the lock out of the tarball and emits one
  # builtin:fetchurl derivation per crate, keyed by the checksum the lock already carries, plus the
  # derivation unpacking them. The result is that derivation's output (builtins.outputOf), so Nix
  # itself does the downloading, caching and hash checking per crate. Needs the daemon to have
  # `dynamic-derivations ca-derivations`. Git dependencies are rejected (they would need a hash).
  cargoVendor = { source }: dynamic "cargo-vendor" ../builder/fetch-cargo.nu { inherit source; };

  # Registry tarballs from the package-lock.json (v2/v3) inside `source` (at `root`), same
  # mechanism as cargoVendor: one builtin:fetchurl per `resolved` URL fixed by its `integrity`.
  # Result: { package-lock.json (resolved -> file:<store path>) }. npm.nu drops that lock in and
  # `npm ci --offline` verifies integrity itself. `lockFile` is for upstreams that ship none.
  npmDeps =
    {
      source,
      root ? ".",
      lockFile ? null,
    }:
    dynamic "npm-deps" ../builder/fetch-npm.nu {
      inherit source root;
      lockFile = if lockFile == null then "" else lockFile;
    };

  # `go mod vendor` output plus the go.sum it came from (go.nu rejects a stale `hash` with it).
  # Module zips are served from the build cache first, downloads are put back into it.
  goModules =
    { source, hash }:
    vendor {
      name = "go-modules";
      inherit hash;
      path = [
        tools.go
        tools.bsdtar
        tools.jig
      ];
      env = {
        inherit source;
        GOPATH = "/tmp/go";
        GOCACHE = "/tmp/go-cache";
        GOFLAGS = "-mod=mod";
        GOTOOLCHAIN = "local";
      };
      script = ''
        mkdir src; ^bsdtar -xf $env.source -C src --strip-components 1
        cd src
        let mods = (open go.sum | lines | split column " " mod ver h1 | where ver !~ "/go.mod$"
          | insert dir {|m| $"($m.mod | str replace -ar "[A-Z]" { $"!($in | str lowercase)" })/@v" })
        let local = "/tmp/proxy"
        let cached = ($mods | where {|m|
          mkdir $"($local)/($m.dir)"
          [zip mod info] | all {|ext| (do { ^jig cache get $"gomod/($m.mod)@($m.ver)/($m.h1)/($ext)" $"($local)/($m.dir)/($m.ver).($ext)" } | complete).exit_code == 0 }
        })
        $env.GOPROXY = $"file://($local),https://proxy.golang.org"
        ^go mod vendor -o $"($env.out)/vendor"
        cp go.sum $env.out
        let dl = $"($env.GOPATH)/pkg/mod/cache/download"
        for m in ($mods | where {|m| $m not-in $cached }) {
          for ext in [zip mod info] {
            let f = $"($dl)/($m.dir)/($m.ver).($ext)"
            if ($f | path exists) { ^jig cache put $"gomod/($m.mod)@($m.ver)/($m.h1)/($ext)" $f | ignore }
          }
        }
      '';
    };

  empty = builtins.path {
    path = ./empty;
    name = "empty";
  };
}
