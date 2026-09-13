// jsem <ghc> [args…]: execs ghc. The first jsem of a build also starts the one broker that
// feeds cabal's `-jsem <name>` semaphore from jigd slots ($JIG_SOCK) until cabal removes it.
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

#include <algorithm>
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
constexpr int kAliveEvery = 50;  // ticks between checks that the semaphore is still linked
constexpr int kExecFailed = 127;
constexpr mode_t kLockMode = 0600;

auto Env(const char* name, const std::string& fallback) -> std::string {
  const char* value = ::getenv(name);  // NOLINT(concurrency-mt-unsafe): before any thread
  return value != nullptr ? value : fallback;
}

// cabal passes one argument "-jsem <name>"
auto JsemName(std::span<char*> args) -> std::string {
  constexpr std::string_view kFlag = "-jsem";
  for (size_t i = 0; i < args.size(); ++i) {
    std::string_view arg = args[i];  // NOLINT(*-unchecked-container-access): i < size
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
      return args[i + 1];  // NOLINT(*-unchecked-container-access)
    }
  }
  return {};
}

// one broker per (build, semaphore); the forked broker inherits the flock
auto TakeLock(const std::string& dir, std::string_view name) -> int {
  std::string flat(name);
  std::ranges::replace(flat, '/', '_');
  const std::string file = std::format("{}/.jsem{}.lock", dir, flat);
  // NOLINTNEXTLINE(cppcoreguidelines-pro-type-vararg): open(2)
  const int lock = ::open(file.c_str(), O_RDWR | O_CREAT | O_CLOEXEC, kLockMode);
  if (lock < 0) {
    return -1;
  }
  if (::flock(lock, LOCK_EX | LOCK_NB) != 0) {
    ::close(lock);
    return -1;
  }
  return lock;
}

[[noreturn]] void RunBroker(const std::string& name, jsem::Sem& sem, const std::string& socket_path) {
  ::setsid();
  {
    jsem::Broker broker(sem, jsem::DaemonSource(socket_path, Env("NIX_BUILD_TOP", "-")));
    for (int tick = 0;; ++tick) {
      if (tick % kAliveEvery == 0 && jsem::Sem::Open(name) == nullptr) {
        break;
      }
      broker.Tick();
      std::this_thread::sleep_for(kTick);
    }
  }
  ::_exit(0);
}
}  // namespace

#ifndef JSEM_DEFAULT_SOCK                             // package.nix passes the store-relative one
#define JSEM_DEFAULT_SOCK "/nix/var/nix/jigd/socket"  // NOLINT(cppcoreguidelines-macro-usage): -D default
#endif

auto main(int argc, char** argv) -> int {  // NOLINT(bugprone-exception-escape): std::format of literals
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
  if (!name.empty() && jsem::DaemonUp(socket_path)) {
    const int lock = TakeLock(Env("NIX_BUILD_TOP", Env("TMPDIR", "/tmp")), name);
    if (lock >= 0) {
      std::unique_ptr<jsem::Sem> sem = jsem::Sem::Open(name);
      if (!sem) {
        std::fputs(std::format("jsem: cannot open semaphore {}: errno {}\n", name, errno).c_str(), stderr);
        ::close(lock);
      } else if (::fork() == 0) {
        RunBroker(name, *sem, socket_path);
      }
    }
  }
  ::execv(args.at(1), &args.at(1));
  std::fputs(std::format("jsem: exec {}: errno {}\n", args.at(1), errno).c_str(), stderr);
  return kExecFailed;
}
