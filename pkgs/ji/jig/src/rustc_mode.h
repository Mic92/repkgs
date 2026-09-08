// rustc mode (argv[0] = rustcwrap, cargo's RUSTC_WRAPPER). Same two-key scheme as C: the crate
// root is the primary source, rustc's dep-info lists every module file (the manifest inputs),
// --extern rlibs are hashed into k1. Artifacts = every rule head in the dep-info (rlib, rmeta,
// .d), stored as one blob. Cargo always passes --out-dir and --emit=dep-info,…, so the command
// line is left untouched. bin/cdylib/proc-macro crates go through an external linker and are
// not cached.
#ifndef PKGS_CC_RUSTC_MODE_H_
#define PKGS_CC_RUSTC_MODE_H_

#include <span>
#include <string>
#include <vector>

namespace jig {

struct RustInvocation {
  std::vector<std::string> args;
  std::vector<std::string> key_args;
  std::vector<std::string> externs;
  std::string source;
  std::string crate_name;
  std::string out_dir;
  // -C metadata / -C extra-filename are cargo's dependency-graph hash: they name the outputs but
  // do not change their contents beyond that name, so they stay out of the key. Artifacts are
  // stored with the stem replaced by "@" and renamed on restore
  std::string extra_filename;
  bool cacheable = true;
  bool has_dep_info = false;
};

auto ParseRustInvocation(std::span<const std::string> args) -> RustInvocation;

auto RunRustcMode(std::span<const std::string> args, const std::string& socket_path) -> int;

}  // namespace jig

#endif  // PKGS_CC_RUSTC_MODE_H_
