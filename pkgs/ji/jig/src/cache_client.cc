#include "cache_client.h"

#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>
#include <zstd.h>

#include <algorithm>
#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <format>
#include <iterator>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

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

namespace {

// values on the wire: u32 raw size (host order, the cache is per machine) + one zstd frame.
// zstd-1 over lz4: 3x smaller on our objects/manifests for ~the same client CPU (experiments/cdc)
constexpr size_t kHeader = sizeof(std::uint32_t);
constexpr int kLevel = 1;

auto Compress(std::string_view value) -> std::string {
  std::string out;
  out.resize_and_overwrite(kHeader + ZSTD_compressBound(value.size()), [&](char* data, size_t capacity) -> size_t {
    const std::span<char> buf(data, capacity);
    const auto header = std::bit_cast<std::array<char, kHeader>>(static_cast<std::uint32_t>(value.size()));
    std::ranges::copy(header, buf.begin());
    const size_t written =
        ZSTD_compress(buf.subspan(kHeader).data(), capacity - kHeader, value.data(), value.size(), kLevel);
    return ZSTD_isError(written) != 0U ? 0 : kHeader + written;
  });
  return out;
}

auto Decompress(std::string_view wire) -> std::optional<std::string> {
  if (wire.size() < kHeader) {
    return std::nullopt;
  }
  std::array<char, kHeader> header{};
  std::ranges::copy(wire.substr(0, kHeader), header.begin());
  const auto size = std::bit_cast<std::uint32_t>(header);
  std::string out;
  bool valid = true;
  out.resize_and_overwrite(size, [&](char* data, size_t capacity) -> size_t {
    const std::string_view block = wire.substr(kHeader);
    const size_t got = ZSTD_decompress(data, capacity, block.data(), block.size());
    valid = got == capacity;
    return valid ? capacity : 0;
  });
  return valid ? std::optional(std::move(out)) : std::nullopt;
}

}  // namespace

auto CacheClient::RecvValue() -> std::optional<std::string> {
  const std::optional<std::string> line = RecvLine();
  if (!line || !line->starts_with("OK ")) {
    return std::nullopt;
  }
  const std::optional<std::uint64_t> len = ParseUint(std::string_view(*line).substr(3));
  if (!len || *len > kMaxObjectSize) {
    fd_ = UniqueFd();  // a confused server must not drive our allocation, and the stream is lost
    return std::nullopt;
  }
  const std::optional<std::string> wire = RecvExactly(static_cast<size_t>(*len));
  return wire ? Decompress(*wire) : std::nullopt;
}

auto CacheClient::Get(std::string_view key) -> std::optional<std::string> {
  if (!fd_.valid() || !SendAll(std::format("GET {}\n", key))) {
    return std::nullopt;
  }
  return RecvValue();
}

auto CacheClient::GetMany(std::span<const std::string> keys) -> std::vector<std::optional<std::string>> {
  std::vector<std::optional<std::string>> values(keys.size());
  std::string request;
  for (const std::string& key : keys) {
    request += std::format("GET {}\n", key);
  }
  if (!fd_.valid() || keys.empty() || !SendAll(request)) {
    return values;
  }
  for (std::optional<std::string>& value : values) {
    value = RecvValue();
  }
  return values;
}

auto CacheClient::Identities(std::span<const std::string> paths) -> std::vector<std::string> {
  if (!fd_.valid() || paths.empty()) {
    return {};
  }
  std::string request = std::format("IDS {}\n", paths.size());
  for (const std::string& path : paths) {
    request += path + "\n";
  }
  if (!SendAll(request)) {
    return {};
  }
  std::vector<std::string> ids;
  ids.reserve(paths.size());
  for (size_t i = 0; i < paths.size(); ++i) {
    std::optional<std::string> line = RecvLine();
    if (!line) {
      return {};
    }
    ids.push_back(std::move(*line));
  }
  return ids;
}

auto CacheClient::AcquireSlot(std::string_view build) -> bool {
  if (!fd_.valid() || !SendAll(std::format("SLOT {}\n", build))) {
    return false;
  }
  const std::optional<std::string> line = RecvLine();
  return line && *line == "OK";
}

void CacheClient::ReleaseSlot(std::string_view build) {
  if (fd_.valid() && SendAll(std::format("DONE {}\n", build))) {
    RecvLine();
  }
}

void CacheClient::Put(std::string_view key, std::string_view value) {
  if (!fd_.valid()) {
    return;
  }
  const std::string wire = Compress(value);
  if (!wire.empty() && SendAll(std::format("PUT {} {}\n", key, wire.size())) && SendAll(wire)) {
    RecvLine();
  }
}

void CacheClient::PutMany(std::span<const std::pair<std::string, std::string>> items) {
  if (!fd_.valid() || items.empty()) {
    return;
  }
  size_t sent = 0;
  for (const auto& [key, value] : items) {
    const std::string wire = Compress(value);
    if (wire.empty() || !SendAll(std::format("PUT {} {}\n", key, wire.size())) || !SendAll(wire)) {
      break;
    }
    ++sent;
  }
  for (size_t i = 0; i < sent; ++i) {
    RecvLine();
  }
}

auto CacheClient::HasMany(std::span<const std::string> keys) -> std::vector<bool> {
  std::vector<bool> have(keys.size(), false);
  std::string request;
  for (const std::string& key : keys) {
    request += std::format("HAS {}\n", key);
  }
  if (!fd_.valid() || keys.empty() || !SendAll(request)) {
    return have;
  }
  for (auto&& has : have) {
    const std::optional<std::string> line = RecvLine();
    has = line && *line == "1";
  }
  return have;
}

}  // namespace jig
