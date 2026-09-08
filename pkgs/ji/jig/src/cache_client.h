// Client for the cache daemon on an AF_UNIX socket (pkgs/pk/pkgs-cache).
//   "GET key\n"             -> "OK <len>\n<bytes>" | "MISS\n"
//   "PUT key <len>\n<bytes>" -> "OK\n"
// Values are LZ4-block compressed by the client. Any I/O problem is reported as a miss / ignored
// put: the cache is an optimisation only.
#ifndef PKGS_CC_CACHE_CLIENT_H_
#define PKGS_CC_CACHE_CLIENT_H_

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "base.h"

namespace jig {

// largest value accepted from the server (objects, rlib bundles) Anything bigger is a protocol error
constexpr std::uint64_t kMaxObjectSize = std::uint64_t{2} << 30U;  // also LZ4_MAX_INPUT_SIZE

class CacheClient {
 public:
  // false if the socket is absent or refuses. Callers then compile without the cache
  auto Connect(const std::string& socket_path) -> bool;
  [[nodiscard]] auto connected() const -> bool { return fd_.valid(); }

  auto Get(std::string_view key) -> std::optional<std::string>;
  void Put(std::string_view key, std::string_view value);

 private:
  auto SendAll(std::string_view data) -> bool;
  auto Fill() -> bool;
  auto RecvLine() -> std::optional<std::string>;
  auto RecvExactly(size_t count) -> std::optional<std::string>;

  UniqueFd fd_;
  static constexpr size_t kBufSize = 65536;
  std::vector<char> buf_ = std::vector<char>(kBufSize);
  std::string_view pending_;
};

}  // namespace jig

#endif  // PKGS_CC_CACHE_CLIENT_H_
