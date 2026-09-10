// jsem <program> [args…]: run it with $JSEM naming a POSIX semaphore that hands out jigd
// slots ($JIG_SOCK) as GHC -jsem tokens. A caller may fix the name via $JSEM (cabal hashes
// ghc-options into unit ids, a fresh name per build would defeat its store).
#include <stdlib.h>  // NOLINT(modernize-deprecated-headers): setenv is POSIX, not <cstdlib>
#include <sys/wait.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <cstdio>
#include <format>
#include <memory>
#include <span>
#include <string>
#include <thread>
#include <vector>

#include "broker.h"

namespace {
constexpr auto kTick = std::chrono::milliseconds(10);
constexpr int kExecFailed = 127;

auto Env(const char* name, const std::string& fallback) -> std::string {
  const char* v = ::getenv(name);  // NOLINT(concurrency-mt-unsafe): before any thread
  return v != nullptr ? v : fallback;
}
}  // namespace

#ifndef JSEM_DEFAULT_SOCK
#define JSEM_DEFAULT_SOCK "/nix/var/nix/jigd/socket"  // package.nix passes the store-relative one
#endif

auto main(int argc, char** argv) -> int {
  const std::span<char*> args(argv, static_cast<size_t>(argc));
  if (args.size() < 2) {
    std::fputs("usage: jsem <program> [args...]\n", stderr);
    return 2;
  }
  const std::string socket_path = Env("JIG_SOCK", JSEM_DEFAULT_SOCK);
  const std::string build = Env("NIX_BUILD_TOP", "-");
  const std::string name = Env("JSEM", std::format("/jsem_{}", ::getpid()));
  if (!jsem::DaemonUp(socket_path)) {
    std::fputs(std::format("jsem: no jigd at JIG_SOCK={}\n", socket_path).c_str(), stderr);
    return 1;
  }
  const std::unique_ptr<jsem::Sem> sem = jsem::Sem::Create(name, 0);
  if (!sem) {
    std::fputs(std::format("jsem: cannot create semaphore {}: errno {}\n", name, errno).c_str(), stderr);
    return 1;
  }
  ::setenv("JSEM", name.c_str(), 1);  // NOLINT(concurrency-mt-unsafe): no threads yet

  const pid_t child = ::fork();
  if (child < 0) {
    return 1;
  }
  if (child == 0) {
    ::execvp(args[1], &args[1]);
    std::fputs(std::format("jsem: exec {}: errno {}\n", args[1], errno).c_str(), stderr);
    ::_exit(kExecFailed);
  }
  int status = 0;
  {
    jsem::Broker broker(*sem, jsem::DaemonSource(socket_path, build));
    while (::waitpid(child, &status, WNOHANG) != child) {
      broker.Tick();
      std::this_thread::sleep_for(kTick);
    }
  }
  return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
