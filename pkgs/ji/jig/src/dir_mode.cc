// Listing format, one line per entry: "<kind> <mode-octal> <hash-or-target>\t<relpath>".
// kind f: regular file, blob under b/<hash>. kind l: symlink, third field is the target.
// Directories are implied by the paths. Blobs go up in batches the daemon does not yet have.
#include "dir_mode.h"

#include <sys/stat.h>

#include <algorithm>
#include <cstddef>
#include <cstdio>
#include <filesystem>
#include <format>
#include <optional>
#include <print>
#include <span>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>
#include <vector>

#include "base.h"
#include "cache_client.h"
#include "keys.h"

namespace jig {

namespace {

constexpr size_t kBatch = 256;
constexpr int kOctal = 8;
constexpr unsigned kDefaultMode = 0644;
constexpr unsigned kPermBits = 0777;

auto BlobKey(std::string_view hash_hex) -> std::string { return std::format("b/{}", hash_hex); }

struct Entry {
  char kind = 'f';
  unsigned mode = kDefaultMode;
  std::string ref;  // content hash (f) or link target (l)
  std::string rel;
};

auto ParseListing(std::string_view text) -> std::vector<Entry> {
  std::vector<Entry> entries;
  for (const std::string& line : Split(text, '\n')) {
    const size_t tab = line.find('\t');
    const std::vector<std::string> head = SplitWhitespace(std::string_view(line).substr(0, tab));
    if (tab == std::string::npos || head.size() != 3) {
      continue;
    }
    entries.push_back({
        .kind = head.at(0).at(0),
        .mode = static_cast<unsigned>(ParseUint(head.at(1), kOctal).value_or(kDefaultMode)),
        .ref = head.at(2),
        .rel = line.substr(tab + 1),
    });
  }
  return entries;
}

struct Pending {
  std::string blob_key;
  fs::path file;
};

// uploads the files of `pending` whose blob the daemon lacks, returns how many that was
auto Upload(CacheClient& cache, std::span<const Pending> pending) -> size_t {
  std::vector<std::string> keys;
  keys.reserve(pending.size());
  for (const Pending& item : pending) {
    keys.push_back(item.blob_key);
  }
  const std::vector<bool> have = cache.HasMany(keys);
  std::vector<std::pair<std::string, std::string>> puts;
  for (size_t i = 0; i < pending.size(); ++i) {
    if (i < have.size() && have.at(i)) {
      continue;
    }
    if (std::optional<std::string> data = ReadFile(pending.at(i).file)) {
      puts.emplace_back(pending.at(i).blob_key, std::move(*data));
    }
  }
  cache.PutMany(puts);
  return puts.size();
}

}  // namespace

auto PutDir(const std::string& socket_path, const std::string& key, const std::string& dir) -> int {
  CacheClient cache;
  if (!cache.Connect(socket_path)) {
    return 2;
  }
  std::string listing;
  std::vector<Pending> pending;
  size_t files = 0;
  size_t uploaded = 0;
  const fs::path root(dir);
  for (const fs::directory_entry& dent : fs::recursive_directory_iterator(root)) {
    const std::string rel = dent.path().lexically_relative(root).string();
    if (dent.is_symlink()) {
      listing += std::format("l 0 {}\t{}\n", fs::read_symlink(dent.path()).string(), rel);
      continue;
    }
    if (!dent.is_regular_file()) {
      continue;
    }
    const std::optional<std::string> data = ReadFile(dent.path());
    if (!data) {
      continue;
    }
    struct stat sta{};
    ::stat(dent.path().c_str(), &sta);
    const std::string hash = HashOf(*data).hex();
    listing += std::format("f {:o} {}\t{}\n", sta.st_mode & kPermBits, hash, rel);
    pending.push_back({.blob_key = BlobKey(hash), .file = dent.path()});
    ++files;
    if (pending.size() == kBatch) {
      uploaded += Upload(cache, pending);
      pending.clear();
    }
  }
  uploaded += Upload(cache, pending);
  cache.Put(key, listing);
  std::println(stderr, "jig: put-dir {}: {} files, {} new", key, files, uploaded);
  return 0;
}

auto GetDir(const std::string& socket_path, const std::string& key, const std::string& dir) -> int {
  CacheClient cache;
  if (!cache.Connect(socket_path)) {
    return 2;
  }
  const std::optional<std::string> listing = cache.Get(key);
  if (!listing) {
    return 1;
  }
  std::vector<Entry> entries = ParseListing(*listing);
  const fs::path root(dir);
  std::error_code ignored;
  for (const Entry& entry : entries) {
    if (entry.kind == 'l') {
      const fs::path dest = root / entry.rel;
      fs::create_directories(dest.parent_path(), ignored);
      fs::remove(dest, ignored);
      fs::create_symlink(entry.ref, dest, ignored);
    }
  }
  std::erase_if(entries, [](const Entry& entry) -> bool { return entry.kind != 'f'; });
  size_t missing = 0;
  for (size_t start = 0; start < entries.size(); start += kBatch) {
    const std::span<const Entry> batch = std::span(entries).subspan(start, std::min(kBatch, entries.size() - start));
    std::vector<std::string> keys;
    keys.reserve(batch.size());
    for (const Entry& entry : batch) {
      keys.push_back(BlobKey(entry.ref));
    }
    const std::vector<std::optional<std::string>> blobs = cache.GetMany(keys);
    for (size_t i = 0; i < batch.size(); ++i) {
      const fs::path dest = root / batch.at(i).rel;
      fs::create_directories(dest.parent_path(), ignored);
      const std::optional<std::string>& blob = i < blobs.size() ? blobs.at(i) : std::nullopt;
      if (!blob.has_value() || !WriteFile(dest, *blob)) {
        ++missing;
        continue;
      }
      ::chmod(dest.c_str(), batch.at(i).mode);
    }
  }
  std::println(stderr, "jig: get-dir {}: {} files, {} missing", key, entries.size(), missing);
  return missing == 0 ? 0 : 1;
}

}  // namespace jig
