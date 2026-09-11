// The two-key scheme shared by the C and rustc modes.
//   k1 = H(tool, cwd, normalised args, primary source bytes)   -> manifest: "input\tid" lines
//   k2 = H(k1, manifest)                                        -> artifacts
// A manifest is valid when every input still has the same id (see Store::InputId).
#pragma once

#include <expected>
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

// one IDS round trip for the store files among `paths`. InputId then finds them without hashing
void PrefetchIdentities(CacheClient& cache, std::span<const std::string> paths);

// `inputs` minus `primary_source` (already in k1) and minus unreadable paths.
auto BuildManifest(CacheClient& cache, const RequestKey& request_key, std::span<const std::string> inputs,
                   std::string_view primary_source) -> Manifest;

// Recompute k2 from a stored manifest, or "inputs-changed:<path>" for the first input whose
// identity moved or vanished
auto ValidateManifest(CacheClient& cache, const RequestKey& request_key, std::string_view manifest_text)
    -> std::expected<ResultKey, std::string>;

// k1 -> manifest -> k2, or why not ("new-key" when k1 has no manifest)
auto FindResult(CacheClient& cache, const RequestKey& request_key) -> std::expected<ResultKey, std::string>;

}  // namespace jig
