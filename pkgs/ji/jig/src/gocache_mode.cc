#include "gocache_mode.h"

#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <format>
#include <fstream>
#include <iostream>
#include <optional>
#include <print>
#include <string>
#include <string_view>
#include <system_error>

#include "keys.h"

#define JSON_NOEXCEPTION 1  // NOLINT(cppcoreguidelines-macro-usage): nlohmann-json's configuration knob
#include <json.hpp>

#include "base.h"
#include "cache_client.h"

namespace jig {

namespace {

// RFC 4648 base64, what Go's encoding/json uses for []byte
constexpr std::string_view kAlphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
constexpr unsigned kSextetBits = 6;
constexpr unsigned kSextetMask = 0x3f;
constexpr unsigned kOctetBits = 8;
constexpr unsigned kOctetMask = 0xff;

auto DecodeChar(char chr) -> std::optional<unsigned> {
  const size_t pos = kAlphabet.find(chr);
  if (pos == std::string_view::npos) {
    return std::nullopt;
  }
  return static_cast<unsigned>(pos);
}

struct GoSession {
  CacheClient cache;
  bool live = false;
  fs::path dir;
  std::int64_t hits = 0;
  std::int64_t misses = 0;
  std::int64_t puts = 0;
};

void HandleGet(GoSession& session, std::int64_t request_id, const std::string& action) {
  std::optional<std::string> output_id;
  std::optional<std::string> body;
  if (session.live) {
    output_id = session.cache.Get(slot::GoAction(action));
  }
  if (output_id) {
    body = session.cache.Get(slot::GoOutput(HexEncode(*output_id)));
  }
  if (!output_id || !body) {
    ++session.misses;
    std::println(stdout, R"({{"ID":{},"Miss":true}})", request_id);
    return;
  }
  ++session.hits;
  const fs::path disk_path = session.dir / HexEncode(*output_id);
  if (!fs::exists(disk_path)) {
    WriteFile(disk_path, *body);
  }
  std::println(stdout, "{}",
               nlohmann::json{
                   {"ID", request_id},
                   {"OutputID", Base64Encode(*output_id)},
                   {"Size", body->size()},
                   {"DiskPath", disk_path.string()},
               }
                   .dump());
}

void HandlePut(GoSession& session, std::int64_t request_id, const std::string& action, const nlohmann::json& req) {
  const std::string output_id = Base64Decode(req.value("OutputID", ""));
  std::string body;
  if (req.value("BodySize", std::int64_t{0}) > 0) {
    // the body follows as one JSON string line (base64), possibly after blank lines
    std::string body_line;
    while (body_line.empty() && std::getline(std::cin, body_line)) {
    }
    const nlohmann::json body_json = nlohmann::json::parse(body_line, nullptr, false);
    if (body_json.is_string()) {
      body = Base64Decode(body_json.get<std::string>());
    }
  }
  const fs::path disk_path = session.dir / HexEncode(output_id);
  WriteFile(disk_path, body);
  if (session.live) {
    session.cache.Put(slot::GoOutput(HexEncode(output_id)), body);
    session.cache.Put(slot::GoAction(action), output_id);
  }
  ++session.puts;
  std::println(stdout, "{}", nlohmann::json{{"ID", request_id}, {"DiskPath", disk_path.string()}}.dump());
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
  unsigned acc = 0;
  unsigned bits = 0;
  for (const char chr : text) {
    const std::optional<unsigned> sextet = DecodeChar(chr);
    if (!sextet) {
      continue;
    }
    acc = (acc << kSextetBits) | *sextet;
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

  std::string line;
  while (std::getline(std::cin, line)) {
    if (line.empty()) {
      continue;
    }
    const nlohmann::json req = nlohmann::json::parse(line, nullptr, /*allow_exceptions=*/false);
    if (req.is_discarded() || !req.is_object()) {
      continue;
    }
    const std::int64_t request_id = req.value("ID", std::int64_t{0});
    const std::string command = req.value("Command", "");
    if (command == "close") {
      std::println(stdout, R"({{"ID":{}}})", request_id);
      std::fflush(stdout);
      break;
    }
    const std::string action = HexEncode(Base64Decode(req.value("ActionID", "")));
    if (command == "get") {
      HandleGet(session, request_id, action);
    } else if (command == "put") {
      HandlePut(session, request_id, action, req);
    }
    std::fflush(stdout);
  }
  if (const std::string log = Env("JIG_LOG"); !log.empty()) {
    std::ofstream(log, std::ios::app) << std::format("gocacheprog hits={} misses={} puts={} live={}\n", session.hits,
                                                     session.misses, session.puts, session.live);
  }
  return 0;
}

}  // namespace jig
