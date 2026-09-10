// jsem <ghc> [args…]: runs ghc, and while it runs feeds the `-jsem <name>` semaphore cabal
// created (cabal --semaphore) with jigd slots ($JIG_SOCK). Without -jsem or without a daemon
// it is a plain exec.
#include <sys/wait.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <format>
#include <memory>
#include <span>
#include <string>
#include <string_view>
#include <thread>

#include "broker.h"

namespace {
constexpr auto kTick = std::chrono::milliseconds(10);
constexpr int kExecFailed = 127;

auto Env(const char* name, const std::string& fallback) -> std::string {
  const char* v = ::getenv(name);  // NOLINT(concurrency-mt-unsafe): before any thread
  return v != nullptr ? v : fallback;
}

// cabal passes one argument "-jsem <name>"
auto JsemName(std::span<char*> args) -> std::string {
  constexpr std::string_view kFlag = "-jsem";
  for (size_t i = 0; i < args.size(); ++i) {
    std::string_view arg = args[i];
    if (!arg.starts_with(kFlag)) {
      continue;
    }
    arg.remove_prefix(kFlag.size());
    while (arg.starts_with(' ')) {
      arg.remove_prefix(1);
    }
    if (!arg.empty()) {
      return std::string(arg);
    }
    if (i + 1 < args.size()) {
      return args[i + 1];
    }
  }
  return {};
}
}  // namespace

#ifndef JSEM_DEFAULT_SOCK
#define JSEM_DEFAULT_SOCK "/nix/var/nix/jigd/socket"  // package.nix passes the store-relative one
#endif

auto main(int argc, char** argv) -> int {
  const std::span<char*> args(argv, static_cast<size_t>(argc));
  if (args.size() < 2) {
    std::fputs("usage: jsem <ghc> [args...]\n", stderr);
    return 2;
  }
  const std::string socket_path = Env("JIG_SOCK", JSEM_DEFAULT_SOCK);
  std::string name = JsemName(args.subspan(2));
  if (!name.empty() && !name.starts_with('/')) {
    name.insert(0, "/");
  }
  std::unique_ptr<jsem::Sem> sem;
  if (!name.empty() && jsem::DaemonUp(socket_path)) {
    sem = jsem::Sem::Open(name);
    if (!sem) {
      std::fputs(std::format("jsem: cannot open semaphore {}: errno {}\n", name, errno).c_str(), stderr);
    }
  }
  if (!sem) {
    ::execv(args[1], &args[1]);
    std::fputs(std::format("jsem: exec {}: errno {}\n", args[1], errno).c_str(), stderr);
    return kExecFailed;
  }

  const pid_t child = ::fork();
  if (child < 0) {
    return 1;
  }
  if (child == 0) {
    ::execv(args[1], &args[1]);
    std::fputs(std::format("jsem: exec {}: errno {}\n", args[1], errno).c_str(), stderr);
    ::_exit(kExecFailed);
  }
  int status = 0;
  {
    jsem::Broker broker(*sem, jsem::DaemonSource(socket_path, Env("NIX_BUILD_TOP", "-")));
    while (::waitpid(child, &status, WNOHANG) != child) {
      broker.Tick();
      std::this_thread::sleep_for(kTick);
    }
  }
  return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
