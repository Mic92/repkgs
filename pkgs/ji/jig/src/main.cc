// jig: the `cc` behind every package. One static binary, mode chosen by argv[0] basename
// (or $JIG_MODE): cc/c++/gcc/g++/clang/clang++ -> compiler driver + compile cache,
// rustcwrap -> cargo RUSTC_WRAPPER, gocacheprog -> GOCACHEPROG server, reloc-fixup -> ELF fixup.
// Built and configured by bootstrap/{jig,cc}.nu. See the mode headers for details.
//
//   JIG_SOCK  cache socket (default /run/pkgs-cache.sock) Absent -> everything runs uncached
//   JIG_LOG   one line per invocation: "<hit|hit-fail|miss-*|plain-*> <source> <ms>"
//   JIG_LOG_ARGS  "<kind>\t<user args>" for every uncached invocation (what to teach the cache next)
//   JIG_STORE_IDENTITY, JIG_STORE_ROOTS  see store.h

#include <cstddef>
#include <filesystem>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "base.h"
#include "cc_mode.h"
#include "fixup_mode.h"
#include "gocache_mode.h"
#include "nix_store_mode.h"
#include "rustc_mode.h"

auto main(int argc, char** argv) -> int {
  const std::span<char*> raw(argv, static_cast<size_t>(argc));
  const std::vector<std::string> args(raw.begin(), raw.end());
  const std::string socket_path = jig::Env("JIG_SOCK", "/run/pkgs-cache.sock");
  const std::string mode_env = jig::Env("JIG_MODE");
  const std::string self = args.empty() ? "" : std::filesystem::path(args.at(0)).filename().string();
  const auto is_mode = [&](std::string_view name) -> bool { return mode_env == name || self == name; };

  if (is_mode("nix-store") || (args.size() > 1 && args.at(1) == "nix-store")) {
    return jig::RunNixStoreMode(std::span(args).subspan(self == "nix-store" ? 1 : 2));
  }
  if (is_mode("gocacheprog")) {
    return jig::RunGoCacheProg(socket_path);
  }
  if (is_mode("rustcwrap") || mode_env == "rustc") {
    return jig::RunRustcMode(args, socket_path);
  }
  if (is_mode("reloc-fixup") || mode_env == "fixup") {
    return jig::RunFixupMode(args);
  }
  return jig::RunCcMode(self, std::span<const std::string>(args).subspan(args.empty() ? 0 : 1), socket_path);
}
