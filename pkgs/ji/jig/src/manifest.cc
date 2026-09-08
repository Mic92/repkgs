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

auto BuildManifest(const RequestKey& request_key, std::span<const std::string> inputs, std::string_view primary_source)
    -> Manifest {
  const Store& store = Store::Get();
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

auto ValidateManifest(const RequestKey& request_key, std::string_view manifest_text) -> std::optional<ResultKey> {
  const Store& store = Store::Get();
  Hasher hasher;
  hasher.Field(request_key.text());
  size_t start = 0;
  while (start < manifest_text.size()) {
    size_t end = manifest_text.find('\n', start);
    if (end == std::string_view::npos) {
      end = manifest_text.size();
    }
    const std::string_view line = manifest_text.substr(start, end - start);
    start = end + 1;
    const size_t tab = line.find('\t');
    if (tab == std::string_view::npos) {
      continue;
    }
    const std::optional<std::string> identity = store.InputId(store.Resolve(std::string(line.substr(0, tab))));
    if (!identity || *identity != line.substr(tab + 1)) {
      return std::nullopt;
    }
    hasher.Field(line);
  }
  return ResultKey(hasher.Finish());
}

}  // namespace jig
