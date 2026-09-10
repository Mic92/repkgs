// jig: the `cc` behind every package. One static binary; the mode is argv[0]'s basename when it
// is a symlink (cc c++ rustcwrap gocacheprog reloc-fixup) or argv[1] when run as `jig <mode>`
// (nix-store, cache, slot). Anything else is the compiler driver + compile cache.
// Built and configured by bootstrap/{jig,cc}.nu. See the mode headers for details.
//
//   JIG_SOCK  cache socket (default <store>/../var/nix/pkgs-cache/socket) Absent -> everything runs uncached
//   JIG_LOG   one line per invocation: "<hit|hit-fail|miss-*|plain-*> <source> <ms>"
//   JIG_LOG_ARGS  "<kind>\t<user args>" for every uncached invocation (what to teach the cache next)
//   JIG_STORE_IDENTITY, JIG_STORE_ROOTS  see store.h

#include <cstddef>
#include <cstdio>
#include <filesystem>
#include <optional>
#include <span>
#include <string>
#include <vector>

#include "base.h"
#include "cache_client.h"
#include "cc_mode.h"
#include "fixup_mode.h"
#include "gocache_mode.h"
#include "keys.h"
#include "nix_store_mode.h"
#include "process.h"
#include "rustc_mode.h"
#include "store.h"

namespace {

// jig cache get|put <key> <file>: plain blobs, for fetchers (nix/fetch.nix goModules)
auto RunCacheMode(std::span<const std::string> args, const std::string& socket_path) -> int {
  if (args.size() != 3) {
    return 1;
  }
  jig::CacheClient cache;
  if (!cache.Connect(socket_path)) {
    return 2;
  }
  const std::string& key = args.at(1);
  const std::string& file = args.at(2);
  if (args.at(0) == "put") {
    const std::optional<std::string> data = jig::ReadFile(file);
    if (data) {
      cache.Put(key, *data);
    }
    return data ? 0 : 1;
  }
  const std::optional<std::string> blob = cache.Get(key);
  return blob && jig::WriteFile(file, *blob) ? 0 : 1;
}

// `jig slot <program> <args…>`: run it holding a daemon slot. For tools that reach a compiler
// without passing through cc/rustcwrap, e.g. `go build -toolexec`.
auto RunSlotMode(std::span<const std::string> args, const std::string& socket_path) -> int {
  if (args.empty()) {
    std::fputs("usage: jig slot <program> [args...]\n", stderr);
    return 2;
  }
  jig::CacheClient cache;
  const jig::Slot slot(cache, socket_path);
  return jig::Run(args.front(), args.subspan(1), jig::StderrMode::kInherit).status;
}

}  // namespace

auto main(int argc, char** argv) -> int {
  const std::span<char*> raw(argv, static_cast<size_t>(argc));
  const std::vector<std::string> all(raw.begin(), raw.end());
  const std::string socket_path = jig::Env("JIG_SOCK", jig::Store::Get().StateDir() + "/pkgs-cache/socket");
  std::string mode = all.empty() ? "" : std::filesystem::path(all.at(0)).filename().string();
  std::span<const std::string> args = std::span(all).subspan(all.empty() ? 0 : 1);
  if (mode == "jig" && !args.empty()) {
    mode = args.front();
    args = args.subspan(1);
  }
  if (mode == "nix-store") {
    return jig::RunNixStoreMode(args);
  }
  if (mode == "cache") {
    return RunCacheMode(args, socket_path);
  }
  if (mode == "slot") {
    return RunSlotMode(args, socket_path);
  }
  if (mode == "gocacheprog") {
    return jig::RunGoCacheProg(socket_path);
  }
  if (mode == "rustcwrap") {
    return jig::RunRustcMode(args, socket_path);
  }
  if (mode == "reloc-fixup") {
    return jig::RunFixupMode(args);
  }
  return jig::RunCcMode(mode, args, socket_path);
}
