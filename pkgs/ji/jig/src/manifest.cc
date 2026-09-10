#include "manifest.h"

#include <cstddef>
#include <format>
#include <optional>
#include <span>
#include <string>
#include <string_view>
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
  std::string path;  // resolved to this build's store roots
  std::string line;  // as stored: "<masked path>\t<identity>"
  size_t tab = 0;
};

auto ParseManifest(std::string_view text) -> std::vector<Entry> {
  const Store& store = Store::Get();
  std::vector<Entry> entries;
  for (std::string& line : Split(text, '\n')) {
    if (const size_t tab = line.find('\t'); tab != std::string::npos) {
      std::string path = store.Resolve(line.substr(0, tab));
      entries.push_back({.path = std::move(path), .line = std::move(line), .tab = tab});
    }
  }
  return entries;
}

// one IDS round trip for the store files among `paths`. InputId then finds them without hashing
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

}  // namespace

auto BuildManifest(CacheClient& cache, const RequestKey& request_key, std::span<const std::string> inputs,
                   std::string_view primary_source) -> Manifest {
  const Store& store = Store::Get();
  PrefetchIdentities(cache, inputs);
  std::string text;
  Hasher hasher;
  hasher.Field(request_key.text());
  for (const std::string& path : inputs) {
    if (path == primary_source) {
      continue;
    }
    const std::optional<std::string> identity = store.InputId(path);
    if (!identity) {
      continue;
    }
    const std::string line = std::format("{}\t{}", store.Key(path), *identity);
    text += line + "\n";
    hasher.Field(line);
  }
  return Manifest{.text = std::move(text), .result_key = ResultKey(hasher.Finish())};
}

auto ValidateManifest(CacheClient& cache, const RequestKey& request_key, std::string_view manifest_text,
                      std::string* stale) -> std::optional<ResultKey> {
  const Store& store = Store::Get();
  const std::vector<Entry> entries = ParseManifest(manifest_text);
  std::vector<std::string> paths;
  paths.reserve(entries.size());
  for (const Entry& entry : entries) {
    paths.push_back(entry.path);
  }
  PrefetchIdentities(cache, paths);
  Hasher hasher;
  hasher.Field(request_key.text());
  for (const Entry& entry : entries) {
    const std::optional<std::string> identity = store.InputId(entry.path);
    if (!identity || *identity != std::string_view(entry.line).substr(entry.tab + 1)) {
      if (stale != nullptr) {
        *stale = entry.line.substr(0, entry.tab);
      }
      return std::nullopt;
    }
    hasher.Field(entry.line);
  }
  return ResultKey(hasher.Finish());
}

}  // namespace jig
