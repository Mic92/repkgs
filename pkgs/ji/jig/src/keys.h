// The cache's vocabulary as types, so a k1 cannot be used where a k2 belongs and an object key
// cannot be spelled by hand.
//
//   RequestKey (k1)  what the build system asked for: tool, cwd, args, primary source bytes
//   ResultKey  (k2)  k1 + the manifest of every other input at the time of the compile
//   Slot             which artifact of an entry: manifest under k1, object/stderr/depfile/status under k2
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <string_view>
#include <utility>

namespace jig {

// 128-bit BLAKE3 prefix, lowercase hex. Only Hasher makes these.
class Digest {
 public:
  static constexpr std::size_t kBytes = 16;  // a cache key, not a signature
  [[nodiscard]] auto hex() const -> const std::string& { return hex_; }
  auto operator==(const Digest&) const -> bool = default;

 private:
  friend class Hasher;
  explicit Digest(std::string hex) : hex_(std::move(hex)) {}
  std::string hex_;
};

// Which front end produced the key. Keeps C, rustc and Go entries apart in one server.
enum class Tool : std::uint8_t { kCc, kRustc };

class RequestKey {
 public:
  RequestKey(Tool tool, const Digest& digest) : text_((tool == Tool::kRustc ? "rs/" : "") + digest.hex()) {}
  [[nodiscard]] auto text() const -> const std::string& { return text_; }

 private:
  std::string text_;
};

class ResultKey {
 public:
  explicit ResultKey(const Digest& digest) : text_(digest.hex()) {}
  [[nodiscard]] auto text() const -> const std::string& { return text_; }
  auto operator==(const ResultKey&) const -> bool = default;

 private:
  std::string text_;
};

// server-side key strings. The only place the "m/", "o/" … prefixes are written
namespace slot {
inline auto Manifest(const RequestKey& key) -> std::string { return "m/" + key.text(); }
inline auto Object(const ResultKey& key) -> std::string { return "o/" + key.text(); }
inline auto Stderr(const ResultKey& key) -> std::string { return "e/" + key.text(); }
inline auto Depfile(const ResultKey& key) -> std::string { return "d/" + key.text(); }
inline auto ExitStatus(const ResultKey& key) -> std::string { return "r/" + key.text(); }
// Go's own content addressing: action id -> output id -> bytes
inline auto GoAction(std::string_view action_hex) -> std::string { return "go/a/" + std::string(action_hex); }
inline auto GoOutput(std::string_view output_hex) -> std::string { return "go/o/" + std::string(output_hex); }
}  // namespace slot

// What happened to one invocation. The JIG_LOG line and the per-build summary count these.
enum class Outcome : std::uint8_t {
  kHit,             // replayed a success
  kHitFail,         // replayed a cached failure
  kMissStored,      // compiled, entry written
  kMissStoredFail,  // failed, failure entry written
  kMissFail,        // failed, not replayable (missing header, link error)
  kMissUnstored,    // succeeded but outputs unreadable
  kPlainCompile,    // uncacheable compile (-E, -S, several sources, …)
  kPlainLink,       // real link
  kPlainNoSource,   // source unreadable
  kPlainNoSocket,   // no cache server
};
auto OutcomeName(Outcome outcome) -> std::string_view;

enum class Language : std::uint8_t { kC, kCxx };
enum class StderrMode : std::uint8_t { kInherit, kCapture };

}  // namespace jig
