#include "manifest.h"

#include <cstddef>
#include <expected>
#include <filesystem>
#include <format>
#include <optional>
#include <set>
#include <span>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>
#include <vector>

#include "base.h"
#include "cache_client.h"
#include "keys.h"
#include "store.h"

namespace jig {

auto ParseDepfile(std::string_view text) -> std::vector<std::string> {
  std::vector<std::string> deps;
  std::string token;
  bool after_colon = false;
  const auto flush = [&] -> void {
    if (token.empty()) {
      return;
    }
    if (after_colon) {
      deps.push_back(token);
    } else if (token.back() == ':') {
      after_colon = true;
    }
    token.clear();
  };
  for (size_t i = 0; i < text.size(); ++i) {
    const char cur = text.at(i);
    const char next = i + 1 < text.size() ? text.at(i + 1) : '\n';
    if (cur == '\\' && next == '\n') {
      ++i;  // line continuation
    } else if (cur == '\\' && next == ' ') {
      token += ' ';  // escaped space in a path
      ++i;
    } else if (cur == '\n') {
      flush();
      if (after_colon) {
        break;  // first rule complete
      }
    } else if (cur == ' ' || cur == '\t') {
      flush();
    } else if (cur == ':' && !after_colon && (next == ' ' || next == '\n' || next == '\\')) {
      after_colon = true;
      token.clear();
    } else {
      token += cur;
    }
  }
  flush();
  return deps;
}

namespace {

struct Entry {
  std::string path;  // in this build's store roots, "" when the build lacks the root
  std::string line;  // as stored: "<masked path>\t<identity>" or "!<masked path>"
  size_t tab = 0;    // npos for a "!" line
};

auto ParseManifest(std::string_view text) -> std::vector<Entry> {
  const Store& store = Store::Get();
  std::vector<Entry> entries;
  for (std::string& line : Split(text, '\n')) {
    if (line.starts_with('!')) {
      std::string path = store.Resolve(line.substr(1)).value_or("");
      entries.push_back({.path = std::move(path), .line = std::move(line), .tab = std::string::npos});
    } else if (const size_t tab = line.find('\t'); tab != std::string::npos) {
      std::string path = store.Resolve(line.substr(0, tab)).value_or("");
      entries.push_back({.path = std::move(path), .line = std::move(line), .tab = tab});
    }
  }
  return entries;
}

auto Exists(const std::string& path) -> bool {
  std::error_code error;
  return std::filesystem::exists(path, error);
}

}  // namespace

void PrefetchIdentities(CacheClient& cache, std::span<const std::string> paths) {
  Store& store = Store::Get();
  std::vector<std::string> ask;
  for (const std::string& path : paths) {
    if (store.DaemonMayIdentify(path)) {
      ask.push_back(path);
    }
  }
  const std::vector<std::string> ids = cache.Identities(ask);
  for (size_t i = 0; i < ids.size(); ++i) {
    if (!ids.at(i).empty()) {
      store.RememberIdentity(ask.at(i), ids.at(i));
    }
  }
}

auto BuildManifest(CacheClient& cache, const RequestKey& request_key, std::span<const std::string> inputs,
                   std::string_view primary_source, std::span<const std::string> absent) -> Manifest {
  const Store& store = Store::Get();
  PrefetchIdentities(cache, inputs);
  std::string text;
  Hasher hasher;
  hasher.Field(request_key.text());
  const auto add = [&](const std::string& line) -> void {
    text += line + "\n";
    hasher.Field(line);
  };
  for (const std::string& path : inputs) {
    if (path == primary_source) {
      continue;
    }
    if (const std::optional<std::string> identity = store.InputId(path)) {
      add(std::format("{}\t{}", store.Key(path), *identity));
    }
  }
  // store paths stay absent; what exists by now the compiler wrote itself (-o, -MF)
  std::set<std::string> seen;
  for (const std::string& path : absent) {
    if (path.empty() || store.IsStorePath(path) || Exists(path)) {
      continue;
    }
    if (const std::string key = "!" + store.Key(path); seen.insert(key).second) {
      add(key);
    }
  }
  return Manifest{.text = std::move(text), .result_key = ResultKey(hasher.Finish())};
}

auto ValidateManifest(CacheClient& cache, const RequestKey& request_key, std::string_view manifest_text)
    -> std::expected<ResultKey, std::string> {
  const Store& store = Store::Get();
  const std::vector<Entry> entries = ParseManifest(manifest_text);
  std::vector<std::string> paths;
  paths.reserve(entries.size());
  for (const Entry& entry : entries) {
    if (entry.tab != std::string::npos) {
      paths.push_back(entry.path);
    }
  }
  PrefetchIdentities(cache, paths);
  Hasher hasher;
  hasher.Field(request_key.text());
  for (const Entry& entry : entries) {
    if (entry.tab == std::string::npos) {
      if (Exists(entry.path)) {
        return std::unexpected("appeared:" + entry.line.substr(1));
      }
    } else {
      const std::optional<std::string> identity = store.InputId(entry.path);
      if (!identity || *identity != std::string_view(entry.line).substr(entry.tab + 1)) {
        return std::unexpected("inputs-changed:" + entry.line.substr(0, entry.tab));
      }
    }
    hasher.Field(entry.line);
  }
  return ResultKey(hasher.Finish());
}

auto FindResult(CacheClient& cache, const RequestKey& request_key) -> std::expected<ResultKey, std::string> {
  const std::optional<std::string> manifest_text = cache.Get(slot::Manifest(request_key));
  if (!manifest_text) {
    return std::unexpected("new-key");
  }
  return ValidateManifest(cache, request_key, *manifest_text);
}

}  // namespace jig
