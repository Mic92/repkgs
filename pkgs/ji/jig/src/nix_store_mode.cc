#include "nix_store_mode.h"

#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <format>
#include <iostream>
#include <iterator>
#include <map>
#include <optional>
#include <print>
#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#define JSON_NOEXCEPTION 1  // NOLINT(cppcoreguidelines-macro-usage): nlohmann-json's configuration knob
#include <json.hpp>

#include "base.h"

namespace jig {

// ---- SHA-256 (FIPS 180-4) and Nix32. Store paths are defined over them, BLAKE3 will not do here. --
// Spec transcriptions: the shift amounts *are* the algorithm and every index is bounded by the
// fixed array extents, so naming constants or routing through .at() would only obscure them.
// NOLINTBEGIN(cppcoreguidelines-avoid-magic-numbers, readability-magic-numbers,
//             cppcoreguidelines-pro-bounds-constant-array-index, readability-identifier-length)

namespace {

constexpr std::array<std::uint32_t, 64> kRoundConstants = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
constexpr std::array<std::uint32_t, 8> kInitialState = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                                                        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
constexpr size_t kBlockBytes = 64;

// SHA-256 is defined over arithmetic mod 2^32: the one place wrap-around is intended
__attribute__((no_sanitize("unsigned-integer-overflow"))) void Compress(
    std::array<std::uint32_t, 8>& state, std::span<const std::uint8_t, kBlockBytes> block) {
  std::array<std::uint32_t, 64> schedule{};
  for (size_t i = 0; i < 16; ++i) {
    schedule[i] = std::uint32_t{block[i * 4]} << 24 | std::uint32_t{block[(i * 4) + 1]} << 16 |
                  std::uint32_t{block[(i * 4) + 2]} << 8 | std::uint32_t{block[(i * 4) + 3]};
  }
  for (size_t i = 16; i < 64; ++i) {
    const std::uint32_t s0 = std::rotr(schedule[i - 15], 7) ^ std::rotr(schedule[i - 15], 18) ^ (schedule[i - 15] >> 3);
    const std::uint32_t s1 = std::rotr(schedule[i - 2], 17) ^ std::rotr(schedule[i - 2], 19) ^ (schedule[i - 2] >> 10);
    schedule[i] = schedule[i - 16] + s0 + schedule[i - 7] + s1;
  }
  std::array<std::uint32_t, 8> work = state;
  for (size_t i = 0; i < 64; ++i) {
    const std::uint32_t s1 = std::rotr(work[4], 6) ^ std::rotr(work[4], 11) ^ std::rotr(work[4], 25);
    const std::uint32_t choose = (work[4] & work[5]) ^ (~work[4] & work[6]);
    const std::uint32_t temp1 = work[7] + s1 + choose + kRoundConstants[i] + schedule[i];
    const std::uint32_t s0 = std::rotr(work[0], 2) ^ std::rotr(work[0], 13) ^ std::rotr(work[0], 22);
    const std::uint32_t majority = (work[0] & work[1]) ^ (work[0] & work[2]) ^ (work[1] & work[2]);
    const std::uint32_t temp2 = s0 + majority;
    work = {temp1 + temp2, work[0], work[1], work[2], work[3] + temp1, work[4], work[5], work[6]};
  }
  for (size_t i = 0; i < 8; ++i) {
    state[i] += work[i];
  }
}

}  // namespace

// Only ever hashes fingerprints (< 1 KiB): store paths are *defined* over SHA-256, file contents
// never pass through here (crate hashes come from Cargo.lock, NAR hashing is the daemon's job).
auto Sha256(std::string_view data) -> std::string {
  std::array<std::uint32_t, 8> state = kInitialState;
  size_t off = 0;
  for (; data.size() - off >= kBlockBytes; off += kBlockBytes) {
    Compress(state, std::span<const std::uint8_t, kBlockBytes>(reinterpret_cast<const std::uint8_t*>(&data[off]),
                                                               kBlockBytes));  // NOLINT
  }
  // tail: remaining bytes, 0x80, zero pad, 64-bit big-endian bit length (one or two blocks)
  std::array<std::uint8_t, kBlockBytes * 2> tail{};
  const size_t rest = data.size() - off;
  std::ranges::copy(data.substr(off), tail.begin());
  tail[rest] = 0x80;
  const size_t tail_len = rest + 1 + 8 <= kBlockBytes ? kBlockBytes : kBlockBytes * 2;
  const std::uint64_t bit_length = std::uint64_t{data.size()} * 8;
  for (size_t i = 0; i < 8; ++i) {
    tail[tail_len - 1 - i] = static_cast<std::uint8_t>((bit_length >> (i * 8)) & 0xffU);
  }
  for (size_t blk = 0; blk < tail_len; blk += kBlockBytes) {
    Compress(state, std::span<const std::uint8_t, kBlockBytes>(&tail[blk], kBlockBytes));
  }
  std::string out;
  for (const std::uint32_t word : state) {
    for (int shift = 24; shift >= 0; shift -= 8) {
      out += static_cast<char>(static_cast<std::uint8_t>((word >> shift) & 0xffU));
    }
  }
  return out;
}

auto Nix32(std::string_view bytes) -> std::string {
  constexpr std::string_view kAlphabet = "0123456789abcdfghijklmnpqrsvwxyz";
  constexpr size_t kBits = 5;
  const size_t length = ((bytes.size() * 8 - 1) / kBits) + 1;
  const auto byte_at = [&](size_t idx) -> unsigned {
    return idx < bytes.size() ? static_cast<unsigned char>(bytes[idx]) : 0U;
  };
  std::string out;
  for (size_t idx = 0; idx < length; ++idx) {
    const size_t bit = (length - 1 - idx) * kBits;
    const unsigned pair = byte_at(bit / 8) | (byte_at((bit / 8) + 1) << 8);
    out += kAlphabet[(pair >> (bit % 8)) & 0x1fU];
  }
  return out;
}

// NOLINTEND(cppcoreguidelines-avoid-magic-numbers, readability-magic-numbers,
//           cppcoreguidelines-pro-bounds-constant-array-index, readability-identifier-length)

// ---- store paths (doc/manual/source/protocols/store-path.md) -----------------------------------

namespace {

constexpr size_t kStorePathHashBytes = 20;

// Nix thesis §5.1: XOR-fold the digest onto 160 bits
auto CompressHash(std::string_view digest) -> std::string {
  std::string out(kStorePathHashBytes, '\0');
  for (size_t i = 0; i < digest.size(); ++i) {
    out.at(i % kStorePathHashBytes) = static_cast<char>(static_cast<unsigned char>(out.at(i % kStorePathHashBytes)) ^
                                                        static_cast<unsigned char>(digest.at(i)));
  }
  return out;
}

auto MakeStorePath(std::string_view store_dir, std::string_view type, std::string_view inner_fingerprint,
                   std::string_view name) -> std::string {
  const std::string fingerprint =
      std::format("{}:sha256:{}:{}:{}", type, HexEncode(Sha256(inner_fingerprint)), store_dir, name);
  return std::format("{}/{}-{}", store_dir, Nix32(CompressHash(Sha256(fingerprint))), name);
}

// what Nix substitutes for a CA input derivation's output path in the consumer's env/args before
// the build (DownstreamPlaceholder::unknownCaOutput): the only way to name such a path up front
auto DownstreamPlaceholder(std::string_view drv_path, std::string_view output) -> std::string {
  const std::string_view base = drv_path.substr(drv_path.rfind('/') + 1);
  const std::string_view hash_part = base.substr(0, base.find('-'));
  std::string_view drv_name = base.substr(base.find('-') + 1);
  drv_name.remove_suffix(4);  // ".drv"
  const std::string output_path_name = output == "out" ? std::string{drv_name} : std::format("{}-{}", drv_name, output);
  return "/" + Nix32(Sha256(std::format("nix-upstream-output:{}:{}", hash_part, output_path_name)));
}

}  // namespace

// flat (file) ingestion only. `algo` is the hash the *file* is fixed by (sha256, sha512, …). The
// path itself is always derived via SHA-256
auto FixedOutputPath(std::string_view store_dir, std::string_view name, std::string_view algo, std::string_view hex)
    -> std::string {
  return MakeStorePath(store_dir, "output:out", std::format("fixed:out:{}:{}:", algo, hex), name);
}

// ---- ATerm (doc/manual/source/protocols/derivation-aterm.md) -----------------------------------

namespace {

auto Quote(std::string_view text) -> std::string {
  std::string out = "\"";
  for (const char chr : text) {
    switch (chr) {
      case '"':
        out += "\\\"";
        break;
      case '\\':
        out += "\\\\";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      default:
        out += chr;
    }
  }
  return out + "\"";
}

template <typename Range, typename Fn>
auto List(const Range& items, Fn render) -> std::string {
  std::string out = "[";
  bool first = true;
  for (const auto& item : items) {
    if (!first) {
      out += ',';
    }
    first = false;
    out += render(item);
  }
  return out + "]";
}

}  // namespace

auto DerivationToATerm(std::string_view json_text) -> std::string {
  const nlohmann::json drv = nlohmann::json::parse(json_text, nullptr, /*allow_exceptions=*/false);
  if (drv.is_discarded() || !drv.is_object()) {
    return {};
  }
  // std::map gives the canonical (sorted, unique) order the format demands
  std::map<std::string, nlohmann::json> outputs;
  for (const auto& [name, spec] : drv.value("outputs", nlohmann::json::object()).items()) {
    outputs.emplace(name, spec);
  }
  std::map<std::string, std::vector<std::string>> input_drvs;
  for (const auto& [path, outs] : drv.value("inputDrvs", nlohmann::json::object()).items()) {
    std::vector<std::string> names = outs.get<std::vector<std::string>>();
    std::ranges::sort(names);
    input_drvs.emplace(path, std::move(names));
  }
  std::vector<std::string> input_srcs = drv.value("inputSrcs", std::vector<std::string>{});
  std::ranges::sort(input_srcs);
  std::map<std::string, std::string> env;
  for (const auto& [key, value] : drv.value("env", nlohmann::json::object()).items()) {
    env.emplace(key, value.get<std::string>());
  }
  const std::vector<std::string> args = drv.value("args", std::vector<std::string>{});

  std::string out = "Derive(";
  out += List(outputs, [](const auto& entry) -> std::string {
    const auto& [name, spec] = entry;
    return std::format("({},{},{},{})", Quote(name), Quote(spec.value("path", "")), Quote(spec.value("hashAlgo", "")),
                       Quote(spec.value("hash", "")));
  });
  out += ',';
  out += List(input_drvs, [](const auto& entry) -> std::string {
    const auto& [path, names] = entry;
    return std::format("({},{})", Quote(path), List(names, Quote));
  });
  out += ',';
  out += List(input_srcs, Quote);
  out += std::format(",{},{},", Quote(drv.value("system", "")), Quote(drv.value("builder", "")));
  out += List(args, Quote);
  out += ',';
  out += List(env, [](const auto& entry) -> std::string {
    return std::format("({},{})", Quote(entry.first), Quote(entry.second));
  });
  return out + ")";
}

// ---- worker protocol client (builder-rpc-v0 subset) --------------------------------------------

namespace {

constexpr std::uint64_t kWorkerMagic1 = 0x6e697863;
constexpr std::uint64_t kWorkerMagic2 = 0x6478696f;
constexpr std::uint64_t kProtocolVersion = (1U << 8U) | 38U;  // builderRpcV0 = 1.38
constexpr std::uint64_t kStderrNext = 0x6f6c6d67;
constexpr std::uint64_t kStderrLast = 0x616c7473;
constexpr std::uint64_t kStderrError = 0x63787470;
constexpr std::uint64_t kStderrStartActivity = 0x53545254;
constexpr std::uint64_t kStderrStopActivity = 0x53544f50;
constexpr std::uint64_t kStderrResult = 0x52534c54;
constexpr std::uint64_t kOpAddToStore = 7;
constexpr std::uint64_t kOpSubmitOutput = 1000;
constexpr size_t kWordBytes = 8;
constexpr unsigned kByteBits = 8;
constexpr std::uint64_t kByteMask = 0xff;

class DaemonConnection {
 public:
  auto Connect() -> bool {
    constexpr std::string_view kScheme = "unix://";
    std::string remote = Env("NIX_REMOTE");
    if (!remote.starts_with(kScheme)) {
      std::println(stderr, "jig nix-store: NIX_REMOTE={} is not a unix:// socket (builder-rpc-v0 missing?)", remote);
      return false;
    }
    remote.erase(0, kScheme.size());
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    if (remote.size() >= sizeof(addr.sun_path)) {
      return false;
    }
    std::ranges::copy(remote, std::begin(addr.sun_path));
    UniqueFd sock(::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0));
    // NOLINTNEXTLINE(cppcoreguidelines-pro-type-reinterpret-cast): the sockets API is defined this way
    if (!sock.valid() || ::connect(sock.get(), reinterpret_cast<const sockaddr*>(&addr), sizeof(addr)) != 0) {
      std::println(stderr, "jig nix-store: cannot connect to {}", remote);
      return false;
    }
    fd_ = std::move(sock);
    return Handshake();
  }

  // AddToStore with a content-address method ("text:sha256", "fixed:r:sha256", …). Returns the path
  auto AddToStore(std::string_view name, std::string_view method, std::span<const std::string> references,
                  std::string_view contents) -> std::optional<std::string> {
    WriteWord(kOpAddToStore);
    WriteString(name);
    WriteString(method);
    std::vector<std::string> refs(references.begin(), references.end());
    std::ranges::sort(refs);
    WriteWord(refs.size());
    for (const std::string& ref : refs) {
      WriteString(ref);
    }
    WriteWord(0);  // repair = false
    // framed source: one chunk + terminator
    WriteWord(contents.size());
    out_ += contents;
    WriteWord(0);
    if (!Flush() || !DrainStderr()) {
      return std::nullopt;
    }
    // ValidPathInfo: path, deriver?, narHash, refs, regtime, narSize, ultimate, sigs, ca
    std::optional<std::string> path = ReadString();
    if (!path || !ReadString() || !ReadString() || !SkipStrings() || !ReadWord() || !ReadWord() || !ReadWord() ||
        !SkipStrings() || !ReadString()) {
      return std::nullopt;
    }
    return path;
  }

  // this build's <output> := the (already added) store object at `path`
  auto SubmitOutput(std::string_view path, std::string_view output) -> bool {
    WriteWord(kOpSubmitOutput);
    WriteWord(0);  // SingleDerivedPath::Opaque
    WriteString(path);
    WriteString(output);
    return Flush() && DrainStderr() && ReadWord().has_value();
  }

 private:
  auto Handshake() -> bool {
    WriteWord(kWorkerMagic1);
    WriteWord(kProtocolVersion);
    if (!Flush() || ReadWord() != kWorkerMagic2) {
      std::println(stderr, "jig nix-store: bad daemon magic");
      return false;
    }
    const std::optional<std::uint64_t> daemon_version = ReadWord();
    if (!daemon_version || std::min(*daemon_version, kProtocolVersion) < kProtocolVersion) {
      std::println(stderr, "jig nix-store: daemon protocol {} too old", daemon_version.value_or(0));
      return false;
    }
    // feature exchange (>= 1.38): ours, then theirs
    constexpr std::array<std::string_view, 4> kFeatures = {
        "realisation-with-path-not-hash",
        "disable-set-options",
        "add-to-store-scanning",
        "submit-output",
    };
    WriteWord(kFeatures.size());
    for (const std::string_view feature : kFeatures) {
      WriteString(feature);
    }
    if (!Flush() || !SkipStrings()) {
      return false;
    }
    // postHandshake: obsolete cpu affinity (0) and reserveSpace (false), then daemon version + trust
    WriteWord(0);
    WriteWord(0);
    if (!Flush() || !ReadString() || !ReadWord()) {
      return false;
    }
    return DrainStderr();
  }

  // consume log traffic until STDERR_LAST. false (after printing it) on STDERR_ERROR
  auto DrainStderr() -> bool {
    while (true) {
      const std::optional<std::uint64_t> msg = ReadWord();
      if (!msg) {
        return false;
      }
      if (*msg == kStderrLast) {
        return true;
      }
      if (*msg == kStderrError) {
        // Error: "Error", level, name, msg, havePos(0), traces…
        ReadString();
        ReadWord();
        ReadString();
        std::println(stderr, "nix-daemon: {}", ReadString().value_or("?"));
        return false;
      }
      if (*msg == kStderrNext) {
        std::println(stderr, "{}", ReadString().value_or(""));
      } else if (*msg == kStderrStartActivity) {
        ReadWord();
        ReadWord();
        ReadWord();
        ReadString();
        SkipFields();
        ReadWord();
      } else if (*msg == kStderrStopActivity) {
        ReadWord();
      } else if (*msg == kStderrResult) {
        ReadWord();
        ReadWord();
        SkipFields();
      } else {
        std::println(stderr, "jig nix-store: unexpected daemon message {:#x}", *msg);
        return false;
      }
    }
  }

  void WriteWord(std::uint64_t value) {
    for (size_t i = 0; i < kWordBytes; ++i) {
      out_ += static_cast<char>(static_cast<std::uint8_t>((value >> (i * kByteBits)) & kByteMask));
    }
  }
  void WriteString(std::string_view text) {
    WriteWord(text.size());
    out_ += text;
    out_.append((kWordBytes - (text.size() % kWordBytes)) % kWordBytes, '\0');
  }
  auto Flush() -> bool {
    std::string_view pending = out_;
    while (!pending.empty()) {
      const ssize_t sent = ::write(fd_.get(), pending.data(), pending.size());
      if (sent <= 0) {
        return false;
      }
      pending.remove_prefix(static_cast<size_t>(sent));
    }
    out_.clear();
    return true;
  }
  auto ReadBytes(size_t count) -> std::optional<std::string> {
    std::string buf(count, '\0');
    std::span<char> remaining(buf);
    while (!remaining.empty()) {
      const ssize_t got = ::read(fd_.get(), remaining.data(), remaining.size());
      if (got <= 0) {
        return std::nullopt;
      }
      remaining = remaining.subspan(static_cast<size_t>(got));
    }
    return buf;
  }
  auto ReadWord() -> std::optional<std::uint64_t> {
    const std::optional<std::string> bytes = ReadBytes(kWordBytes);
    if (!bytes) {
      return std::nullopt;
    }
    std::uint64_t value = 0;
    for (size_t i = 0; i < kWordBytes; ++i) {
      value |= std::uint64_t{static_cast<unsigned char>((*bytes).at(i))} << (i * kByteBits);
    }
    return value;
  }
  auto ReadString() -> std::optional<std::string> {
    const std::optional<std::uint64_t> size = ReadWord();
    constexpr std::uint64_t kMaxString = 64ULL << 20U;
    if (!size || *size > kMaxString) {
      return std::nullopt;
    }
    std::optional<std::string> text = ReadBytes(static_cast<size_t>(*size));
    if (!text || !ReadBytes(static_cast<size_t>((kWordBytes - (*size % kWordBytes)) % kWordBytes))) {
      return std::nullopt;
    }
    return text;
  }
  auto SkipStrings() -> bool {
    const std::optional<std::uint64_t> count = ReadWord();
    if (!count) {
      return false;
    }
    for (std::uint64_t i = 0; i < *count; ++i) {
      if (!ReadString()) {
        return false;
      }
    }
    return true;
  }
  // logger fields: count, then per field: type(0=int,1=string), value
  void SkipFields() {
    const std::uint64_t count = ReadWord().value_or(0);
    for (std::uint64_t i = 0; i < count; ++i) {
      if (ReadWord().value_or(0) == 1) {
        ReadString();
      } else {
        ReadWord();
      }
    }
  }

  UniqueFd fd_;
  std::string out_;
};

auto ReadStdin() -> std::string { return {std::istreambuf_iterator<char>(std::cin), {}}; }

}  // namespace

auto RunNixStoreMode(std::span<const std::string> args) -> int {
  if (args.empty()) {
    std::println(stderr, "usage: jig nix-store add-text|add-drv|submit|fod-path|placeholder …");
    return 2;
  }
  const std::string& verb = args.at(0);
  if (verb == "fod-path" && args.size() == 4) {
    std::println("{}", FixedOutputPath(JIG_STORE_DIR, args.at(1), args.at(2), args.at(3)));
    return 0;
  }
  if (verb == "placeholder" && args.size() == 3) {
    std::println("{}", DownstreamPlaceholder(args.at(1), args.at(2)));
    return 0;
  }
  if (verb == "aterm") {  // offline: JSON on stdin -> ATerm on stdout
    std::print("{}", DerivationToATerm(ReadStdin()));
    return 0;
  }
  DaemonConnection daemon;
  if (!daemon.Connect()) {
    return 1;
  }
  if ((verb == "add-text" || verb == "add-drv") && args.size() >= 2) {
    std::string contents = ReadStdin();
    if (verb == "add-drv") {
      contents = DerivationToATerm(contents);
      if (contents.empty()) {
        std::println(stderr, "jig nix-store: derivation JSON did not parse");
        return 1;
      }
    }
    const std::optional<std::string> path = daemon.AddToStore(args.at(1), "text:sha256", args.subspan(2), contents);
    if (!path) {
      return 1;
    }
    std::println("{}", *path);
    return 0;
  }
  if (verb == "submit" && args.size() == 3) {
    return daemon.SubmitOutput(args.at(1), args.at(2)) ? 0 : 1;
  }
  std::println(stderr, "jig nix-store: bad arguments");
  return 2;
}

}  // namespace jig
