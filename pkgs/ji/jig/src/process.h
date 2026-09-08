// Running the real compiler.
#ifndef PKGS_CC_PROCESS_H_
#define PKGS_CC_PROCESS_H_

#include <span>
#include <string>

#include "keys.h"

namespace jig {

struct RunResult {
  int status = 1;
  std::string stderr_text;  // only filled for StderrMode::kCapture
};

// execvp(program, [program, args...]) and wait. Exit status 127 if exec failed.
auto Run(const std::string& program, std::span<const std::string> args, StderrMode stderr_mode) -> RunResult;

}  // namespace jig

#endif  // PKGS_CC_PROCESS_H_
