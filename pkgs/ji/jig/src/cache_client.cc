#include "cache_client.h"

#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <format>
#include <iterator>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <utility>

#include "base.h"

namespace jig {

auto CacheClient::Connect(const std::string& socket_path) -> bool {
  sockaddr_un addr{};
  addr.sun_family = AF_UNIX;
  if (socket_path.size() >= sizeof(addr.sun_path)) {
    return false;
  }
  std::ranges::copy(socket_path, std::begin(addr.sun_path));
  UniqueFd sock(::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0));
  if (!sock.valid()) {
    return false;
  }
  // NOLINTNEXTLINE(cppcoreguidelines-pro-type-reinterpret-cast): the sockets API is defined this way
  if (::connect(sock.get(), reinterpret_cast<const sockaddr*>(&addr), sizeof(addr)) != 0) {
    return false;
  }
  fd_ = std::move(sock);
  return true;
}

auto CacheClient::SendAll(std::string_view data) -> bool {
  while (!data.empty()) {
    // MSG_NOSIGNAL: a dying cache server must degrade to a plain compile, not SIGPIPE us
    const ssize_t sent = ::send(fd_.get(), data.data(), data.size(), MSG_NOSIGNAL);
    if (sent <= 0) {
      return false;
    }
    data.remove_prefix(static_cast<size_t>(sent));
  }
  return true;
}

auto CacheClient::Fill() -> bool {
  const ssize_t got = ::read(fd_.get(), buf_.data(), buf_.size());
  if (got <= 0) {
    return false;
  }
  pending_ = std::string_view(buf_.data(), static_cast<size_t>(got));
  return true;
}

auto CacheClient::RecvLine() -> std::optional<std::string> {
  std::string line;
  for (;;) {
    const size_t newline = pending_.find('\n');
    if (newline != std::string_view::npos) {
      line.append(pending_.substr(0, newline));
      pending_.remove_prefix(newline + 1);
      return line;
    }
    line.append(pending_);
    if (!Fill()) {
      return std::nullopt;
    }
  }
}

auto CacheClient::RecvExactly(size_t count) -> std::optional<std::string> {
  std::string out;
  bool complete = true;
  out.resize_and_overwrite(count, [&](char* data, size_t size) -> size_t {
    std::span<char> remaining(data, size);
    while (!remaining.empty()) {
      if (pending_.empty() && !Fill()) {
        complete = false;
        return 0;
      }
      const size_t take = std::min(pending_.size(), remaining.size());
      std::ranges::copy(pending_.substr(0, take), remaining.begin());
      pending_.remove_prefix(take);
      remaining = remaining.subspan(take);
    }
    return size;
  });
  return complete ? std::optional(std::move(out)) : std::nullopt;
}

auto CacheClient::Get(std::string_view key) -> std::optional<std::string> {
  if (!fd_.valid() || !SendAll(std::format("GET {}\n", key))) {
    return std::nullopt;
  }
  const std::optional<std::string> line = RecvLine();
  if (!line || !line->starts_with("OK ")) {
    return std::nullopt;
  }
  const std::optional<std::uint64_t> len = ParseUint(std::string_view(*line).substr(3));
  if (!len || *len > kMaxObjectSize) {
    return std::nullopt;  // a confused server must not drive our allocation
  }
  return RecvExactly(static_cast<size_t>(*len));
}

void CacheClient::Put(std::string_view key, std::string_view value) {
  if (!fd_.valid()) {
    return;
  }
  if (SendAll(std::format("PUT {} {}\n", key, value.size())) && SendAll(value)) {
    RecvLine();
  }
}

}  // namespace jig
