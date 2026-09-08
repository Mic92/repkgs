#include "process.h"

#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <array>
#include <cerrno>
#include <cstddef>
#include <cstdlib>
#include <span>
#include <string>
#include <vector>

#include "base.h"
#include "keys.h"

namespace jig {

namespace {
constexpr int kExecFailedStatus = 127;  // what sh reports for command-not-found
constexpr int kSignalStatusBase = 128;
constexpr size_t kPipeChunk = 4096;
}  // namespace

auto Run(const std::string& program, std::span<const std::string> args, StderrMode stderr_mode) -> RunResult {
  bool capture_stderr = stderr_mode == StderrMode::kCapture;
  std::array<int, 2> pipe_fds{-1, -1};
  if (capture_stderr && ::pipe(pipe_fds.data()) != 0) {
    capture_stderr = false;
  }
  UniqueFd read_end(pipe_fds.at(0));
  UniqueFd write_end(pipe_fds.at(1));

  // execvp wants char* const[]. The strings outlive the child image swap, so copies suffice
  std::vector<std::string> storage;
  storage.reserve(args.size() + 1);
  storage.push_back(program);
  storage.insert(storage.end(), args.begin(), args.end());
  std::vector<char*> argv;
  argv.reserve(storage.size() + 1);
  for (std::string& arg : storage) {
    argv.push_back(arg.data());
  }
  argv.push_back(nullptr);

  const pid_t pid = ::fork();
  if (pid < 0) {
    return RunResult{.status = kExecFailedStatus, .stderr_text = "jig: fork failed\n"};
  }
  if (pid == 0) {
    if (capture_stderr) {
      ::dup2(write_end.get(), STDERR_FILENO);
      read_end.Reset();
      write_end.Reset();
    }
    ::execvp(program.c_str(), argv.data());
    _exit(kExecFailedStatus);
  }

  RunResult result;
  if (capture_stderr) {
    write_end.Reset();
    std::array<char, kPipeChunk> buf{};
    ssize_t got = 0;
    while ((got = ::read(read_end.get(), buf.data(), buf.size())) > 0) {
      result.stderr_text.append(buf.data(), static_cast<size_t>(got));
    }
  }
  int wstatus = 0;
  while (::waitpid(pid, &wstatus, 0) < 0) {
    if (errno != EINTR) {
      return result;
    }
  }
  // shell convention: death by signal N reports as 128+N
  // NOLINTNEXTLINE(misc-include-cleaner): <sys/wait.h> is the documented header for the W* macros
  result.status = WIFEXITED(wstatus) ? WEXITSTATUS(wstatus) : kSignalStatusBase + WTERMSIG(wstatus);
  return result;
}

}  // namespace jig
