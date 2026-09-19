#include "fixup_mode.h"

#include <sys/stat.h>

#include <algorithm>
#include <cctype>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <format>
#include <optional>
#include <print>
#include <set>
#include <span>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>
#include <vector>

#include "base.h"
#include "store.h"

namespace jig {

namespace fs = std::filesystem;

// the file may be read-only (installed 0444): writable for the moment
auto WriteBack(const fs::path& path, const std::string& bytes) -> bool {
  struct stat status{};
  const bool have_mode = ::stat(path.c_str(), &status) == 0;
  if (have_mode) {
    ::chmod(path.c_str(), status.st_mode | S_IWUSR);
  }
  const bool written = WriteFile(path, bytes);
  if (have_mode) {
    ::chmod(path.c_str(), status.st_mode);
  }
  if (!written) {
    std::println(stderr, "{}: cannot write back: {}", path.string(),
                 std::error_code(errno, std::generic_category()).message());
  }
  return written;
}

auto RelativeTo(const fs::path& dir, const fs::path& target, std::string_view anchor) -> std::string {
  std::string rel = target.lexically_normal().lexically_relative(dir).string();
  if (anchor.empty()) {
    return rel;
  }
  return rel == "." ? std::string(anchor) : std::format("{}/{}", anchor, rel);
}

auto FixupContext::Final(const fs::path& path) const -> fs::path {
  const fs::path rel = path.lexically_normal().lexically_relative(prefix);
  return rel.empty() || rel.string().starts_with("..") ? path : (dest / rel).lexically_normal();
}

auto FixupContext::OnDisk(const fs::path& path) const -> fs::path {
  const fs::path rel = path.lexically_normal().lexically_relative(dest);
  return rel.empty() || rel.string().starts_with("..") ? path : (prefix / rel).lexically_normal();
}

namespace {

constexpr size_t kLeakContext = 100;  // bytes of a --deny hit shown

// --deny: store paths that must not appear in any file (finish: build-machine packages when cross)
void CheckDenied(FixupContext& ctx, const fs::path& path, std::string_view data) {
  for (const std::string& hash : ctx.denied) {
    if (const size_t pos = data.find(hash); pos != std::string_view::npos) {
      // up to the first control byte, so a hit in a binary does not spill into the terminal
      std::string_view shown = data.substr(pos, kLeakContext);
      const auto* const control =
          std::ranges::find_if(shown, [](unsigned char chr) -> bool { return std::iscntrl(chr) != 0; });
      shown = shown.substr(0, static_cast<size_t>(control - shown.begin()));
      std::println(stderr, "reloc-fixup: {} refers to build-platform {}", fs::relative(path, ctx.prefix).string(),
                   shown);
      ++ctx.errors;
    }
  }
}

// one RUNPATH element: its text, the directory it denotes, whether ld.so must still search it
void FixOne(FixupContext& ctx, const fs::path& path) {
  if (path.extension() == ".debug") {
    return;
  }
  std::optional<std::string> data = ReadFile(path);
  if (!data) {
    return;
  }
  // a compiler driver's config names the build machine's compiler on purpose
  const fs::path rel = fs::relative(path, ctx.prefix);
  if (rel != "etc/jig.json" && rel != "etc/roots") {
    CheckDenied(ctx, path, *data);
  }
  BinaryImage image(std::move(*data));
  FixElf(ctx, path, image) || FixMachO(ctx, path, image);
}

}  // namespace

auto BinaryImage::CString(std::uint64_t offset) const -> std::string {
  if (offset >= bytes_.size()) {
    return {};
  }
  const size_t end = bytes_.find('\0', offset);
  return bytes_.substr(offset, end == std::string::npos ? std::string::npos : end - offset);
}

auto BinaryImage::WritePadded(std::uint64_t offset, std::uint64_t capacity, std::string_view text) -> bool {
  if (text.size() + 1 > capacity || offset > bytes_.size() || bytes_.size() - offset < capacity) {
    return false;
  }
  bytes_.replace(offset, capacity, std::string(text) + std::string(capacity - text.size(), '\0'));
  return true;
}

auto BinaryImage::Overwrite(std::uint64_t offset, std::string_view bytes) -> bool {
  if (offset > bytes_.size() || bytes_.size() - offset < bytes.size()) {
    return false;
  }
  bytes_.replace(offset, bytes.size(), bytes);
  return true;
}

auto RunFixupMode(std::span<const std::string> args) -> int {
  if (args.empty()) {
    std::println(stderr, "usage: reloc-fixup <prefix> [--dest <store path>] [--sdk <dir>] [--deny <store path>]...");
    return 2;
  }
  FixupContext ctx;
  ctx.prefix = ctx.dest = fs::path(args.front()).lexically_normal();
  for (size_t i = 1; i + 1 < args.size(); i += 2) {
    if (args.at(i) == "--dest") {
      ctx.dest = fs::path(args.at(i + 1)).lexically_normal();
    } else if (args.at(i) == "--sdk") {
      ctx.sdk = args.at(i + 1);
    } else if (args.at(i) == "--deny") {
      ctx.denied.push_back(fs::path(args.at(i + 1)).filename().string().substr(0, kStoreHashLength));
    } else {
      std::println(stderr, "reloc-fixup: unknown argument {}", args.at(i));
      return 2;
    }
  }
  if (!Store::Get().IsStorePath(ctx.dest.string())) {
    std::println(stderr, "reloc-fixup: {} is not under {}", ctx.dest.string(), Store::Get().dir());
    return 2;
  }
  std::set<fs::path> lib_dirs;
  std::vector<fs::path> files;
  std::error_code error;
  for (const fs::directory_entry& entry :
       fs::recursive_directory_iterator(ctx.prefix, fs::directory_options::skip_permission_denied, error)) {
    if (entry.is_symlink() || !entry.is_regular_file()) {
      continue;
    }
    files.push_back(entry.path());
    const std::string name = entry.path().filename().string();
    if ((name.contains(".so") || name.ends_with(".dylib")) && !entry.path().parent_path().string().contains("/debug")) {
      lib_dirs.insert(entry.path().parent_path());
    }
  }
  ctx.own_lib_dirs.assign(lib_dirs.begin(), lib_dirs.end());
  for (const fs::path& file : files) {
    FixOne(ctx, file);
  }
  return ctx.errors == 0 ? 0 : 1;
}

}  // namespace jig
