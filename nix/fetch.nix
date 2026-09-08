# Dependency fetchers. Upstream tarballs themselves come from sources.toml (nix/sources.nix).
# All three emit per-file builtin:fetchurl derivations at build time (dynamic derivations): the
# hashes come from the lock file, none of ours.
{ jig, nu }:
let
  system = builtins.currentSystem;

  # A dynamic derivation: `script` (under builder-rpc-v0, with `jig nix-store`) writes the real
  # derivation into the store and submits its .drv as the output. Callers get that drv's "out".
  producers = builtins.path {
    path = ../builder;
    name = "producers";
    filter = p: _: builtins.match ".*/(dynamic|fetch-[a-z]+)\\.nu" p != null;
  };
  dynamic =
    name: script: env:
    let
      producer = derivation (
        {
          name = "${name}.drv";
          inherit system;
          seed = nu;
          builder = "${nu}/bin/nu";
          args = [ "${producers}/${script}" ];
          PATH = "${jig}/bin:${nu}/bin";
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

in
{
  # Registry crates from the Cargo.lock *inside* `source`, as a directory cargo accepts under
  # [source.vendored]. No hash argument and no checked-in lock file: a small producer derivation
  # (builder-rpc-v0, see builder/fetch-cargo.nu) reads the lock out of the tarball and emits one
  # builtin:fetchurl derivation per crate, keyed by the checksum the lock already carries, plus the
  # derivation unpacking them. The result is that derivation's output (builtins.outputOf), so Nix
  # itself does the downloading, caching and hash checking per crate. Needs the daemon to have
  # `dynamic-derivations ca-derivations`. Git dependencies are rejected (they would need a hash).
  cargoVendor = { source }: dynamic "cargo-vendor" "fetch-cargo.nu" { inherit source; };

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
    dynamic "npm-deps" "fetch-npm.nu" {
      inherit source root;
      lockFile = if lockFile == null then "" else lockFile;
    };

  # GOPROXY=file:// tree for the go.sum inside `source`, hashes from a shared locks table
  # (`uptrack lock`; go.sum's h1: is not a file hash), this repo's locks/go.toml unless the caller
  # passes its own. Same mechanism as cargoVendor; the table only reaches the producer, whose
  # output is this package's subset, so unrelated additions rebuild nothing. go.nu builds with
  # -mod=mod against the tree, offline.
  goModules =
    {
      source,
      root ? ".",
      locks ? ../locks/go.toml,
    }:
    dynamic "go-modules" "fetch-go.nu" { inherit source root locks; };

  empty = builtins.path {
    path = ./empty;
    name = "empty";
  };
}
