#include "gocache_mode.h"

#include <sys/types.h>
#include <unistd.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <format>
#include <optional>
#include <print>
#include <string>
#include <string_view>
#include <system_error>
#include <vector>

#include "base.h"
#include "cache_client.h"
#include "keys.h"

namespace jig {

namespace {

// RFC 4648 base64, what Go's encoding/json uses for []byte
constexpr std::string_view kAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
constexpr unsigned kSextetBits = 6;
constexpr unsigned kSextetMask = 0x3f;
constexpr unsigned kOctetBits = 8;
constexpr unsigned kOctetMask = 0xff;
constexpr std::uint8_t kInvalid = 0xff;
constexpr size_t kByteValues = 256;

constexpr auto MakeDecodeTable() -> std::array<std::uint8_t, kByteValues> {
  std::array<std::uint8_t, kByteValues> table{};
  table.fill(kInvalid);
  for (size_t i = 0; i < kAlphabet.size(); ++i) {
    table.at(static_cast<unsigned char>(kAlphabet.at(i))) = static_cast<std::uint8_t>(i);
  }
  return table;
}
constexpr std::array<std::uint8_t, kByteValues> kDecode = MakeDecodeTable();

// stdin line by line without iostreams: bodies are multi-megabyte base64 lines and libc++'s
// std::getline fetches them a character at a time
class LineReader {
 public:
  auto Next(std::string& line) -> bool {
    line.clear();
    for (;;) {
      const std::string_view pending = std::string_view(buf_.data(), end_).substr(pos_);
      const size_t newline = pending.find('\n');
      if (newline != std::string_view::npos) {
        line.append(pending.substr(0, newline));
        pos_ += newline + 1;
        return true;
      }
      line.append(pending);
      pos_ = end_ = 0;
      const ssize_t got = ::read(STDIN_FILENO, buf_.data(), buf_.size());
      if (got <= 0) {
        return !line.empty();
      }
      end_ = static_cast<size_t>(got);
    }
  }

 private:
  static constexpr size_t kBufSize = size_t{1} << 20U;
  std::vector<char> buf_ = std::vector<char>(kBufSize);
  size_t pos_ = 0;
  size_t end_ = 0;
};

// The requests are flat objects with known keys and no escapes in the values we read
// ({"ID":1,"Command":"get","ActionID":"base64",...}), so a scan for "key": is enough
auto JsonField(std::string_view line, std::string_view key) -> std::string_view {
  const std::string pattern = std::format("\"{}\":", key);
  size_t pos = line.find(pattern);
  if (pos == std::string_view::npos) {
    return {};
  }
  pos += pattern.size();
  if (pos < line.size() && line.at(pos) == '"') {
    const size_t end = line.find('"', pos + 1);
    return end == std::string_view::npos ? std::string_view{} : line.substr(pos + 1, end - pos - 1);
  }
  const size_t end = line.find_first_of(",}", pos);
  return line.substr(pos, end == std::string_view::npos ? std::string_view::npos : end - pos);
}

auto JsonInt(std::string_view line, std::string_view key) -> std::int64_t {
  return static_cast<std::int64_t>(ParseUint(JsonField(line, key)).value_or(0));
}

struct GoSession {
  CacheClient cache;
  bool live = false;
  fs::path dir;
};

void HandleGet(GoSession& session, std::int64_t request_id, const std::string& action) {
  const Stopwatch clock;
  std::optional<std::string> output_id;
  std::optional<std::string> body;
  if (session.live) {
    output_id = session.cache.Get(slot::GoAction(action));
  }
  if (output_id) {
    body = session.cache.Get(slot::GoOutput(HexEncode(*output_id)));
  }
  if (!output_id || !body) {
    std::println(stdout, R"({{"ID":{},"Miss":true}})", request_id);
    return;
  }
  LogOutcome("go", Outcome::kHit, action, clock);
  const fs::path disk_path = session.dir / HexEncode(*output_id);
  if (!fs::exists(disk_path)) {
    WriteFile(disk_path, *body);
  }
  std::println(stdout, R"({{"ID":{},"OutputID":"{}","Size":{},"DiskPath":"{}"}})", request_id, Base64Encode(*output_id),
               body->size(), disk_path.string());
}

void HandlePut(GoSession& session, LineReader& input, std::int64_t request_id, const std::string& action,
               std::string_view req) {
  const Stopwatch clock;
  const std::string output_id = Base64Decode(JsonField(req, "OutputID"));
  std::string body;
  if (JsonInt(req, "BodySize") > 0) {
    // the body follows as one JSON string line: "base64", possibly after blank lines
    std::string body_line;
    while (body_line.empty() && input.Next(body_line)) {
    }
    if (body_line.size() >= 2 && body_line.front() == '"' && body_line.back() == '"') {
      body = Base64Decode(std::string_view(body_line).substr(1, body_line.size() - 2));
    }
  }
  const fs::path disk_path = session.dir / HexEncode(output_id);
  WriteFile(disk_path, body);
  if (session.live) {
    session.cache.Put(slot::GoOutput(HexEncode(output_id)), body);
    session.cache.Put(slot::GoAction(action), output_id);
  }
  LogOutcome("go", Outcome::kMissStored, action, clock);
  std::println(stdout, R"({{"ID":{},"DiskPath":"{}"}})", request_id, disk_path.string());
}

}  // namespace

auto Base64Encode(std::string_view bytes) -> std::string {
  std::string out;
  out.reserve((bytes.size() + 2) / 3 * 4);
  unsigned acc = 0;
  unsigned bits = 0;
  for (const char chr : bytes) {
    acc = (acc << kOctetBits) | static_cast<unsigned char>(chr);
    bits += kOctetBits;
    while (bits >= kSextetBits) {
      bits -= kSextetBits;
      out += kAlphabet.at((acc >> bits) & kSextetMask);
    }
    acc &= (1U << bits) - 1;  // at most 4 pending bits
  }
  if (bits > 0) {
    out += kAlphabet.at((acc << (kSextetBits - bits)) & kSextetMask);
  }
  while (out.size() % 4 != 0) {
    out += '=';
  }
  return out;
}

auto Base64Decode(std::string_view text) -> std::string {
  std::string out;
  out.reserve(text.size() / 4 * 3);
  unsigned acc = 0;
  unsigned bits = 0;
  for (const char chr : text) {
    const std::uint8_t sextet = kDecode.at(static_cast<unsigned char>(chr));
    if (sextet == kInvalid) {
      continue;
    }
    acc = (acc << kSextetBits) | sextet;
    bits += kSextetBits;
    if (bits >= kOctetBits) {
      bits -= kOctetBits;
      out += static_cast<char>(static_cast<unsigned char>((acc >> bits) & kOctetMask));
    }
    acc &= (1U << bits) - 1;  // at most 6 pending bits
  }
  return out;
}

auto RunGoCacheProg(const std::string& socket_path) -> int {
  GoSession session;
  session.live = session.cache.Connect(socket_path);
  session.dir = Env("GOCACHEPROG_DIR", Env("TMPDIR", "/tmp") + "/gocacheprog");
  std::error_code ignored;
  fs::create_directories(session.dir, ignored);
  std::println(stdout, R"({{"ID":0,"KnownCommands":["get","put","close"]}})");
  std::fflush(stdout);

  LineReader input;
  std::string line;
  while (input.Next(line)) {
    if (line.empty()) {
      continue;
    }
    const std::int64_t request_id = JsonInt(line, "ID");
    const std::string_view command = JsonField(line, "Command");
    if (command == "close") {
      std::println(stdout, R"({{"ID":{}}})", request_id);
      std::fflush(stdout);
      break;
    }
    const std::string action = HexEncode(Base64Decode(JsonField(line, "ActionID")));
    if (command == "get") {
      HandleGet(session, request_id, action);
    } else if (command == "put") {
      HandlePut(session, input, request_id, action, line);
    }
    std::fflush(stdout);
  }
  return 0;
}

}  // namespace jig
