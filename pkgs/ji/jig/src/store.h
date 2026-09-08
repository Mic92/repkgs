// Nix store awareness: what counts as immutable, and how store paths enter cache keys.
// The store directory is a compile-time constant (-DJIG_STORE_DIR="..." from builtins.storeDir).
//
// JIG_STORE_IDENTITY=path (default): a store file is identified by its path and store paths in
//   arguments are hashed verbatim - exact and free for an immutable store.
// JIG_STORE_IDENTITY=content: store hashes are masked ("/nix/store/*-name/...") in keys and
//   manifests, and store files are hashed like any other. A rebuilt-but-identical toolchain or
//   dependency then still hits. JIG_STORE_ROOTS lists extra store dirs (any text containing
//   them) that masked names may resolve to, beyond those on the command line.
#ifndef PKGS_CC_STORE_H_
#define PKGS_CC_STORE_H_

#ifndef JIG_STORE_DIR
#error "compile with -DJIG_STORE_DIR=\"<nix store dir>\""
#endif

#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace jig {

class Store {
 public:
  static auto Get() -> Store&;

  [[nodiscard]] auto dir() const -> const std::string& { return dir_; }
  [[nodiscard]] auto identity_by_content() const -> bool { return by_content_; }

  [[nodiscard]] auto IsStorePath(std::string_view path) const -> bool;
  // "/nix/store/<32 hash chars>-name" -> "/nix/store/*-name", every occurrence
  [[nodiscard]] auto MaskHashes(std::string text) const -> std::string;
  // the form a string takes inside a cache key: path-like text lexically normalised ("./a//b/../c"
  // == "a/c", so build systems that spell the same -I differently share entries), then store hashes
  // masked in content mode. Lexical only: never touches the file system, symlinks are not followed.
  [[nodiscard]] auto Key(std::string_view arg) const -> std::string;
  // a whole text (depfile) as stored for later replay: hashes masked in content mode, nothing else
  [[nodiscard]] auto MaskForReplay(std::string text) const -> std::string {
    return by_content_ ? MaskHashes(std::move(text)) : text;
  }

  // Content mode: remember every concrete store root mentioned in `text` so masked manifest
  // entries can be mapped back to real files in *this* build.
  void LearnRoots(std::string_view text);
  [[nodiscard]] auto Resolve(const std::string& masked_path) const -> std::string;
  // every store path in a text (a cached depfile) rewritten to this build's roots
  [[nodiscard]] auto ResolveAll(std::string text) const -> std::string;

  // Identity of a file for manifest validation, nullopt if unreadable.
  [[nodiscard]] auto InputId(const std::string& path) const -> std::optional<std::string>;
  // Identity of a tool (compiler) for request keys: symlink-resolved, never hash-masked.
  // Masking would make seed-1/clang and seed-2/clang (or two rustc versions) the same key
  [[nodiscard]] static auto ToolId(const std::string& path) -> std::string;

 private:
  Store();
  std::string dir_ = JIG_STORE_DIR;
  bool by_content_ = false;
  std::vector<std::pair<std::string, std::string>> masked_to_real_;
};

}  // namespace jig

#endif  // PKGS_CC_STORE_H_
