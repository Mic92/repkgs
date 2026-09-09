// Running the real compiler.
#ifndef PKGS_CC_PROCESS_H_
#define PKGS_CC_PROCESS_H_

#include <span>
#include <string>

#include "keys.h"

namespace jig {

class CacheClient;

// Host-wide admission (pkgs-cache SLOT/DONE): several nix builds each running make -j$(nproc)
// would otherwise start max-jobs × nproc compilers. Held around every real compiler or linker run,
// never for a cache hit. Sets JIG_SLOT so a jig the child spawns (rustc -> cc for linking) does
// not wait for a second one. No daemon, or JIG_SLOT already set: no-op.
class Slot {
 public:
  Slot(CacheClient& cache, const std::string& socket_path);
  ~Slot();
  Slot(const Slot&) = delete;
  auto operator=(const Slot&) -> Slot& = delete;
  Slot(Slot&&) = delete;
  auto operator=(Slot&&) -> Slot& = delete;

 private:
  CacheClient* cache_ = nullptr;
  std::string build_;
};

struct RunResult {
  int status = 1;
  std::string stderr_text;  // only filled for StderrMode::kCapture
};

// execvp(program, [program, args...]) and wait. Exit status 127 if exec failed.
auto Run(const std::string& program, std::span<const std::string> args, StderrMode stderr_mode) -> RunResult;

}  // namespace jig

#endif  // PKGS_CC_PROCESS_H_
