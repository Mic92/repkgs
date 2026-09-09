// The two-key scheme shared by the C and rustc modes.
//   k1 = H(tool, cwd, normalised args, primary source bytes)   -> manifest: "input\tid" lines
//   k2 = H(k1, manifest)                                        -> artifacts
// A manifest is valid when every input still has the same id (see Store::InputId).
#ifndef PKGS_CC_MANIFEST_H_
#define PKGS_CC_MANIFEST_H_

#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "keys.h"

namespace jig {

class CacheClient;

// Prerequisites of the first rule of a make-style depfile. With -MP the compiler appends one
// phony "header:" rule per header. Those are not read.
auto ParseDepfile(std::string_view text) -> std::vector<std::string>;

struct Manifest {
  std::string text;  // "path\tid\n" per input, store paths masked in content mode
  ResultKey result_key;
};

// Both ask the daemon (one round trip) for the identities of store files first, so only build-tree
// inputs are hashed here. An unconnected client just means everything is hashed locally.

// `inputs` minus `primary_source` (already in k1) and minus unreadable paths.
auto BuildManifest(CacheClient& cache, const RequestKey& request_key, std::span<const std::string> inputs,
                   std::string_view primary_source) -> Manifest;

// Recompute k2 from a stored manifest. Returns nullopt if any input changed or vanished.
auto ValidateManifest(CacheClient& cache, const RequestKey& request_key, std::string_view manifest_text)
    -> std::optional<ResultKey>;

}  // namespace jig

#endif  // PKGS_CC_MANIFEST_H_
