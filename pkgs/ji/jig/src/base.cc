#include "base.h"

#include <blake3.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <array>
#include <charconv>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <format>
#include <fstream>
#include <ios>
#include <iterator>
#include <memory>
#include <optional>
#include <ratio>
#include <span>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>
#include <vector>

#include "keys.h"

namespace jig {

UniqueFd::~UniqueFd() { Reset(); }

auto UniqueFd::operator=(UniqueFd&& other) noexcept -> UniqueFd& {
  if (this != &other) {
    Reset(other.Release());
  }
  return *this;
}

auto UniqueFd::Release() -> int {
  const int raw_fd = fd_;
  fd_ = -1;
  return raw_fd;
}

void UniqueFd::Reset(int raw_fd) {
  if (fd_ >= 0) {
    ::close(fd_);
  }
  fd_ = raw_fd;
}

constexpr size_t kReadChunk = size_t{1} << 16U;

auto ReadFile(const fs::path& path) -> std::optional<std::string> {
  // NOLINTNEXTLINE(cppcoreguidelines-pro-type-vararg): open(2) is variadic in POSIX, no mode needed for O_RDONLY
  const UniqueFd file(::open(path.c_str(), O_RDONLY | O_CLOEXEC));
  if (!file.valid()) {
    return std::nullopt;
  }
  // regular files: one read of the known size (+1 to see EOF). Others grow chunk by chunk
  struct stat info{};
  const size_t known = ::fstat(file.get(), &info) == 0 && info.st_size > 0 ? static_cast<size_t>(info.st_size) : 0;
  std::string out;
  size_t filled = 0;
  bool failed = false;
  for (size_t want = known > 0 ? known + 1 : kReadChunk; !failed; want = filled + kReadChunk) {
    out.resize_and_overwrite(want, [&](char* data, size_t capacity) -> size_t {
      const std::span<char> buf(data, capacity);
      while (filled < capacity) {
        const ssize_t got = ::read(file.get(), buf.subspan(filled).data(), capacity - filled);
        if (got <= 0) {
          failed = got < 0;
          break;
        }
        filled += static_cast<size_t>(got);
        if (known > 0) {
          break;  // a short read of a regular file is EOF
        }
      }
      return filled;
    });
    if (filled < want) {
      break;
    }
  }
  return failed ? std::nullopt : std::optional(std::move(out));
}

auto WriteFile(const fs::path& path, std::string_view data) -> bool {
  const fs::path tmp = path.parent_path() / std::format(".jig{}.{}", ::getpid(), path.filename().string());
  {
    std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
    if (!out.write(data.data(), static_cast<std::streamsize>(data.size()))) {
      return false;
    }
  }
  std::error_code error;
  fs::rename(tmp, path, error);
  return !error;
}

auto Env(const char* name, std::string_view fallback) -> std::string {
  const char* value = std::getenv(name);  // NOLINT(concurrency-mt-unsafe): single-threaded
  return value != nullptr ? std::string(value) : std::string(fallback);
}

auto SplitWhitespace(std::string_view text) -> std::vector<std::string> {
  std::vector<std::string> out;
  size_t pos = 0;
  while (pos < text.size()) {
    while (pos < text.size() && (text.at(pos) == ' ' || text.at(pos) == '\t' || text.at(pos) == '\n')) {
      ++pos;
    }
    const size_t start = pos;
    while (pos < text.size() && text.at(pos) != ' ' && text.at(pos) != '\t' && text.at(pos) != '\n') {
      ++pos;
    }
    if (pos > start) {
      out.emplace_back(text.substr(start, pos - start));
    }
  }
  return out;
}

auto Split(std::string_view text, char sep, bool keep_empty) -> std::vector<std::string> {
  std::vector<std::string> out;
  size_t start = 0;
  while (start <= text.size()) {
    size_t end = text.find(sep, start);
    if (end == std::string_view::npos) {
      end = text.size();
    }
    if (keep_empty || end > start) {
      out.emplace_back(text.substr(start, end - start));
    }
    start = end + 1;
  }
  return out;
}

auto Join(std::span<const std::string> parts, std::string_view sep) -> std::string {
  std::string out;
  for (const std::string& part : parts) {
    if (!out.empty()) {
      out += sep;
    }
    out += part;
  }
  return out;
}

auto Trim(std::string_view text) -> std::string_view {
  while (!text.empty() && (text.front() == ' ' || text.front() == '\t')) {
    text.remove_prefix(1);
  }
  while (!text.empty() && (text.back() == ' ' || text.back() == '\t')) {
    text.remove_suffix(1);
  }
  return text;
}

auto ReplaceAll(std::string text, std::string_view from, std::string_view replacement) -> std::string {
  if (from.empty()) {
    return text;
  }
  for (size_t pos = 0; (pos = text.find(from, pos)) != std::string::npos; pos += replacement.size()) {
    text.replace(pos, from.size(), replacement);
  }
  return text;
}

auto ParseUint(std::string_view text, int base) -> std::optional<std::uint64_t> {
  text = Trim(text);
  std::uint64_t value = 0;
  // NOLINTNEXTLINE(bugprone-suspicious-stringview-data-usage): from_chars takes [first, last), not a C string
  const auto [ptr, errc] = std::from_chars(text.begin(), text.end(), value, base);
  if (errc != std::errc() || ptr != text.end()) {
    return std::nullopt;
  }
  return value;
}

auto HexEncode(std::string_view bytes) -> std::string {
  std::string out;
  out.reserve(bytes.size() * 2);
  for (const char byte : bytes) {
    std::format_to(std::back_inserter(out), "{:02x}", static_cast<unsigned char>(byte));
  }
  return out;
}

struct Hasher::State {
  blake3_hasher h;
};

Hasher::Hasher() : state_(std::make_unique<State>()) { blake3_hasher_init(&state_->h); }
Hasher::~Hasher() = default;

auto Hasher::Update(std::string_view data) -> Hasher& {
  blake3_hasher_update(&state_->h, data.data(), data.size());
  return *this;
}

auto Hasher::Field(std::string_view data) -> Hasher& {
  // length-prefixed so no byte sequence inside a field can fake a boundary
  const std::string len = std::to_string(data.size()) + ":";
  blake3_hasher_update(&state_->h, len.data(), len.size());
  return Update(data);
}

auto Hasher::Finish() const -> Digest {
  std::array<std::uint8_t, Digest::kBytes> out{};
  blake3_hasher_finalize(&state_->h, out.data(), out.size());
  std::string bytes;
  for (const std::uint8_t byte : out) {
    bytes += static_cast<char>(byte);
  }
  return Digest(HexEncode(bytes));
}

auto HashOf(std::string_view data) -> Digest { return Hasher().Update(data).Finish(); }

auto Stopwatch::ElapsedMs() const -> double {
  return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start_).count();
}

auto OutcomeName(Outcome outcome) -> std::string_view {
  switch (outcome) {
    case Outcome::kHit:
      return "hit";
    case Outcome::kHitFail:
      return "hit-fail";
    case Outcome::kMissStored:
      return "miss-stored";
    case Outcome::kMissStoredFail:
      return "miss-stored-fail";
    case Outcome::kMissFail:
      return "miss-fail";
    case Outcome::kMissUnstored:
      return "miss-unstored";
    case Outcome::kPlainCompile:
      return "plain-compile";
    case Outcome::kPlainLink:
      return "plain-link";
    case Outcome::kPlainNoSource:
      return "plain-nosrc";
    case Outcome::kPlainNoSocket:
      return "plain-nosock";
  }
  return "?";
}

void LogOutcome(Outcome outcome, std::string_view subject, const Stopwatch& clock, std::string_view prefix) {
  static const std::string path = Env("JIG_LOG");
  if (path.empty()) {
    return;
  }
  std::ofstream out(path, std::ios::app);
  out << std::format("{}{} {} {:.2f}ms\n", prefix, OutcomeName(outcome), subject, clock.ElapsedMs());
}

}  // namespace jig
