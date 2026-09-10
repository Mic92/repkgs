#include "store.h"

#include <algorithm>
#include <cstddef>
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>
#include <vector>

#include "base.h"

namespace jig {

namespace {
constexpr std::string_view kDepfileDelimiters = " \t\n\\:";
}  // namespace

auto Store::Get() -> Store& {
  static Store instance;
  return instance;
}

Store::Store() : by_content_(Env("JIG_STORE_IDENTITY", "path") == "content"), out_(Env("out")) {
  if (!by_content_) {
    return;
  }
  std::vector<std::string> roots = Split(Env("JIG_STORE_ROOTS"), ' ');
  roots.push_back(out_);
  for (std::string& root : roots) {
    root.resize(std::min(root.size(), root.find('/', dir_.size() + 1)));  // <store>/<hash-name>[/…]
    if (std::string masked = MaskHashes(root); masked != root) {
      masked_to_real_.emplace(std::move(masked), std::move(root));
    }
  }
}

auto Store::IsStorePath(std::string_view path) const -> bool {
  return path.size() > dir_.size() && path.starts_with(dir_) && path.at(dir_.size()) == '/';
}

auto Store::MaskHashes(std::string text) const -> std::string {
  const std::string prefix = dir_ + "/";
  for (size_t pos = 0; (pos = text.find(prefix, pos)) != std::string::npos;) {
    const size_t hash_start = pos + prefix.size();
    if (text.size() > hash_start + kStoreHashLength && text.at(hash_start + kStoreHashLength) == '-') {
      text.replace(hash_start, kStoreHashLength, "*");
    }
    pos = hash_start + 1;
  }
  return text;
}

namespace {

// -Ipath, -I path (already split), --flag=path, plain path. Anything containing a '/' after the
// option prefix is treated as a path and normalised. Other text passes through untouched.
auto NormalizePathArg(std::string_view arg) -> std::string {
  // macro definitions are program text, not paths: -DSRC="./x" must stay distinct from -DSRC="x"
  if (arg.starts_with("-D") || arg.starts_with("-U")) {
    return std::string(arg);
  }
  size_t start = 0;
  if (arg.starts_with("--")) {
    const size_t equals = arg.find('=');
    if (equals == std::string_view::npos) {
      return std::string(arg);
    }
    start = equals + 1;
  } else if (arg.starts_with('-') && arg.size() > 2 && arg.at(1) != '-') {
    // single-dash option glued to its value (-Ifoo, -include is its own token so has no '/')
    start = 2;
    if (const size_t equals = arg.find('='); equals != std::string_view::npos && !arg.substr(0, equals).contains('/')) {
      start = equals + 1;
    }
  } else if (arg.starts_with('-')) {
    return std::string(arg);
  }
  const std::string_view value = arg.substr(start);
  if (!value.contains('/') && !value.starts_with('.')) {
    return std::string(arg);
  }
  std::string normal = std::filesystem::path(value).lexically_normal().string();
  if (normal.size() > 1 && normal.ends_with('/')) {
    normal.pop_back();
  }
  if (normal.empty()) {
    normal = ".";
  }
  return std::string(arg.substr(0, start)) + normal;
}

}  // namespace

auto Store::Key(std::string_view arg) const -> std::string {
  std::string key = NormalizePathArg(arg);
  return by_content_ ? MaskHashes(std::move(key)) : key;
}

auto Store::Resolve(const std::string& path) const -> std::optional<std::string> {
  if (!path.starts_with(dir_ + "/*-")) {
    return path;
  }
  const size_t slash = path.find('/', dir_.size() + 3);
  const auto root = masked_to_real_.find(path.substr(0, slash));
  if (root == masked_to_real_.end()) {
    return std::nullopt;
  }
  return root->second + (slash == std::string::npos ? "" : path.substr(slash));
}

auto Store::ResolveAll(std::string text) const -> std::string {
  text = MaskHashes(std::move(text));
  const std::string mark = dir_ + "/*-";
  for (size_t pos = 0; (pos = text.find(mark, pos)) != std::string::npos;) {
    size_t end = text.find_first_of(kDepfileDelimiters, pos);
    if (end == std::string::npos) {
      end = text.size();
    }
    const std::string real = Resolve(text.substr(pos, end - pos)).value_or(text.substr(pos, end - pos));
    text.replace(pos, end - pos, real);
    pos += real.size();
  }
  return text;
}

auto Store::ToolId(const std::string& path) const -> std::string {
  const std::filesystem::path tool(path);
  std::error_code error;
  const std::filesystem::path dir = std::filesystem::canonical(tool.parent_path(), error);
  return Key(error ? path : (dir / tool.filename()).string());
}

auto Store::DaemonMayIdentify(std::string_view path) const -> bool {
  const bool under_out =
      !out_.empty() && path.starts_with(out_) && (path.size() == out_.size() || path.at(out_.size()) == '/');
  return by_content_ && IsStorePath(path) && !under_out;
}

void Store::RememberIdentity(const std::string& path, std::string identity) {
  known_ids_.insert_or_assign(path, std::move(identity));
}

auto Store::InputId(const std::string& path) const -> std::optional<std::string> {
  if (IsStorePath(path) && !by_content_) {
    return "S:" + path;
  }
  if (const auto known = known_ids_.find(path); known != known_ids_.end()) {
    return known->second;
  }
  const std::optional<std::string> content = ReadFile(path);
  if (!content) {
    return std::nullopt;
  }
  return "C:" + HashOf(*content).hex();
}

}  // namespace jig
