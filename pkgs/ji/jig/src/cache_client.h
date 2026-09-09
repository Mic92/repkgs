// Client for the cache daemon on an AF_UNIX socket (pkgs/pk/pkgs-cache).
//   "GET key\n"             -> "OK <len>\n<bytes>" | "MISS\n"
//   "PUT key <len>\n<bytes>" -> "OK\n"
//   "IDS <n>\n" + n paths   -> n identity lines ("" = unreadable): the daemon memoises store files
//   "SLOT <build>\n" -> "OK\n" when a compiler may start, "DONE <build>\n" -> "OK\n" (see process.h Slot)
// Requests may be pipelined: GetMany/Identities write all questions, then read all answers.
// Values are zstd-compressed by the client. Any I/O problem is reported as a miss / ignored
// put: the cache is an optimisation only.
#ifndef PKGS_CC_CACHE_CLIENT_H_
#define PKGS_CC_CACHE_CLIENT_H_

#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "base.h"

namespace jig {

// largest value accepted from the server (objects, rlib bundles) Anything bigger is a protocol error
constexpr std::uint64_t kMaxObjectSize = std::uint64_t{2} << 30U;

class CacheClient {
 public:
  // false if the socket is absent or refuses. Callers then compile without the cache
  auto Connect(const std::string& socket_path) -> bool;
  [[nodiscard]] auto connected() const -> bool { return fd_.valid(); }

  auto Get(std::string_view key) -> std::optional<std::string>;
  // several GETs in one write, answers in order
  auto GetMany(std::span<const std::string> keys) -> std::vector<std::optional<std::string>>;
  void Put(std::string_view key, std::string_view value);
  // one identity per path in order, empty where the daemon could not read it. Empty vector on error
  auto Identities(std::span<const std::string> paths) -> std::vector<std::string>;
  // blocks until the daemon admits one more compiler for `build`. false: no daemon, run anyway
  auto AcquireSlot(std::string_view build) -> bool;
  void ReleaseSlot(std::string_view build);

 private:
  auto SendAll(std::string_view data) -> bool;
  auto Fill() -> bool;
  auto RecvLine() -> std::optional<std::string>;
  auto RecvValue() -> std::optional<std::string>;
  auto RecvExactly(size_t count) -> std::optional<std::string>;

  UniqueFd fd_;
  static constexpr size_t kBufSize = 65536;
  std::vector<char> buf_ = std::vector<char>(kBufSize);
  std::string_view pending_;
};

}  // namespace jig

#endif  // PKGS_CC_CACHE_CLIENT_H_
