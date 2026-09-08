// `jig nix-store <verb>`: the two store operations a builder running under Nix's
// `builder-rpc-v0` feature may perform, spoken directly over the worker-protocol socket in
// $NIX_REMOTE. This is what lets a build emit derivations it computed itself (dynamic
// derivations) without a nix binary in the sandbox.
//
//   jig nix-store add-text <name> [<ref>...] < text     -> prints the store path
//   jig nix-store add-drv  <name> [<ref>...] < json     -> ATerm-encodes, adds, prints path
//   jig nix-store submit   <store-path> <output>        -> this build's <output> := that object
//   jig nix-store fod-path <name> <algo> <hex>            -> store path of a flat fixed output
//
// add-drv JSON: {"name", "system", "builder", "args":[], "env":{}, "inputDrvs":{path:[outputs]},
//                "inputSrcs":[], "outputs":{name:{"hashAlgo"?, "hash"?, "path"?}}}
// (a subset of `nix derivation show`; enough for fixed, floating-CA and text outputs)
#ifndef PKGS_CC_NIX_STORE_MODE_H_
#define PKGS_CC_NIX_STORE_MODE_H_

#include <span>
#include <string>
#include <string_view>

namespace jig {

auto RunNixStoreMode(std::span<const std::string> args) -> int;

// exposed for tests
auto Nix32(std::string_view bytes) -> std::string;
auto Sha256(std::string_view data) -> std::string;  // raw 32 bytes
auto FixedOutputPath(std::string_view store_dir, std::string_view name, std::string_view algo, std::string_view hex)
    -> std::string;
auto DerivationToATerm(std::string_view json_text) -> std::string;

}  // namespace jig

#endif  // PKGS_CC_NIX_STORE_MODE_H_
