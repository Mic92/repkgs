// rustc mode (argv[0] = rustcwrap, cargo's RUSTC_WRAPPER). Same two-key scheme as C: the crate
// root is the primary source, rustc's dep-info lists every module file (the manifest inputs),
// --extern rlibs are hashed into k1. Artifacts = every rule head in the dep-info (rlib, rmeta,
// .d), stored as one blob. Cargo always passes --out-dir and --emit=dep-info,…, so the command
// line is left untouched. Crates that link (bin, proc-macro, cdylib, dylib) are not cached:
// the ELF embeds interp, RUNPATH and native libraries as absolute store paths.
#pragma once

#include <span>
#include <string>
#include <string_view>
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
  bool links = false;
  bool has_crate_type = false;
  bool cacheable = true;
  bool query = false;  // --print, -vV, `-` as source: cargo probing rustc, not a build step
  bool has_dep_info = false;
};

auto ParseRustInvocation(std::span<const std::string> args) -> RustInvocation;

// dep-info: one "output: inputs…" rule per artifact, then "input:" phony rules and "# …"
// comments. Inputs come back absolute
struct DepInfo {
  std::vector<std::string> outputs;
  std::vector<std::string> inputs;
};
auto ParseDepInfo(std::string_view text) -> DepInfo;

auto RunRustcMode(std::span<const std::string> args, const std::string& socket_path) -> int;

}  // namespace jig
