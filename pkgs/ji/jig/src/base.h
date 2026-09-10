// Small utilities shared by every jig mode: files, environment, strings, hashing, timing.
// No exceptions anywhere in jig: fallible operations return std::optional / bool.
#pragma once

#include <chrono>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "keys.h"

// Built with libc++ hardening (pkgs/ji/jig/bootstrap.nu): container/span/string_view indexing and
// optional dereference are bounds-checked at runtime and trap, so plain operator[] is safe here.
namespace jig {

namespace fs = std::filesystem;

// Owns a POSIX file descriptor.
class UniqueFd {
 public:
  UniqueFd() = default;
  explicit UniqueFd(int raw_fd) : fd_(raw_fd) {}
  ~UniqueFd();
  UniqueFd(UniqueFd&& other) noexcept : fd_(other.Release()) {}
  auto operator=(UniqueFd&& other) noexcept -> UniqueFd&;
  UniqueFd(const UniqueFd&) = delete;
  auto operator=(const UniqueFd&) -> UniqueFd& = delete;

  [[nodiscard]] auto get() const -> int { return fd_; }
  [[nodiscard]] auto valid() const -> bool { return fd_ >= 0; }
  auto Release() -> int;
  void Reset(int raw_fd = -1);

 private:
  int fd_ = -1;
};

auto ReadFile(const fs::path& path) -> std::optional<std::string>;
// Write via temp file + rename: a reader that has the previous file mmapped (llvm-ar under
// parallel make) must never see it truncated in place. The temp name starts with a dot so
// build-system globs on the real name ($(wildcard *.dt)) do not pick it up.
auto WriteFile(const fs::path& path, std::string_view data) -> bool;

auto Env(const char* name, std::string_view fallback = {}) -> std::string;

auto SplitWhitespace(std::string_view text) -> std::vector<std::string>;
// `@file` arguments replaced by the file's words (GNU quoting). A @word that names no readable
// file stays as it is, like gcc and clang do
auto ExpandResponseFiles(std::span<const std::string> args) -> std::vector<std::string>;
auto Split(std::string_view text, char sep, bool keep_empty = false) -> std::vector<std::string>;
auto Join(std::span<const std::string> parts, std::string_view sep) -> std::string;
auto Trim(std::string_view text) -> std::string_view;
auto ReplaceAll(std::string text, std::string_view from, std::string_view replacement) -> std::string;
constexpr int kDecimal = 10;
auto ParseUint(std::string_view text, int base = kDecimal) -> std::optional<std::uint64_t>;

auto HexEncode(std::string_view bytes) -> std::string;

// BLAKE3 over a sequence of fields. Field() adds a separator so ("ab","c") != ("a","bc").
class Hasher {
 public:
  Hasher();
  ~Hasher();
  Hasher(const Hasher&) = delete;
  auto operator=(const Hasher&) -> Hasher& = delete;
  Hasher(Hasher&&) = delete;
  auto operator=(Hasher&&) -> Hasher& = delete;

  auto Update(std::string_view data) -> Hasher&;
  auto Field(std::string_view data) -> Hasher&;
  [[nodiscard]] auto Finish() const -> Digest;  // first 128 bits: a cache key, not a signature

 private:
  struct State;  // keeps blake3.h out of every translation unit
  std::unique_ptr<State> state_;
};

auto HashOf(std::string_view data) -> Digest;

class Stopwatch {
 public:
  [[nodiscard]] auto ElapsedMs() const -> double;

 private:
  std::chrono::steady_clock::time_point start_ = std::chrono::steady_clock::now();
};

// one $JIG_LOG line if set: "<tool>\t<outcome>\t<subject>\t<ms>", summed up by builder/finish.nu
void LogOutcome(std::string_view tool, Outcome outcome, std::string_view subject, const Stopwatch& clock);

}  // namespace jig
