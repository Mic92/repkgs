// The Mach-O half of reloc-fixup: dyld resolves @loader_path against the directory of the image
// holding the load command, so every LC_LOAD_DYLIB and LC_RPATH naming a store path is respelled
// that way and the tree loads from wherever it is copied. Like ELF's direct $ORIGIN NEEDED, no
// rpath search involved. A longer string grows its load command into the header padding the
// linker left (-headerpad_max_install_names).
#include <algorithm>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <print>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>
#include <vector>

#include "base.h"
#include "fixup_mode.h"
#include "nix_store_mode.h"
#include "store.h"

namespace jig {

namespace {

namespace fs = std::filesystem;

// <mach-o/loader.h>, which only the SDK has
constexpr std::uint32_t kMagic64 = 0xfeedfacf;
constexpr std::uint32_t kReqDyld = 0x80000000U;
constexpr std::uint32_t kLoadDylib = 0xc;
constexpr std::uint32_t kIdDylib = 0xd;
constexpr std::uint32_t kLoadWeakDylib = 0x18U | kReqDyld;
constexpr std::uint32_t kRpath = 0x1cU | kReqDyld;
constexpr std::uint32_t kReexportDylib = 0x1fU | kReqDyld;
constexpr std::uint32_t kLoadUpwardDylib = 0x23U | kReqDyld;
constexpr std::uint32_t kCodeSignature = 0x1d;
constexpr std::uint32_t kSegment64 = 0x19;
constexpr std::uint8_t kSha256Size = 32;
struct MachHeader64 {
  std::uint32_t magic;
  std::uint32_t cputype;
  std::uint32_t cpusubtype;
  std::uint32_t filetype;
  std::uint32_t ncmds;
  std::uint32_t sizeofcmds;
  std::uint32_t flags;
  std::uint32_t reserved;
};
struct LoadCommand {
  std::uint32_t cmd;
  std::uint32_t cmdsize;
};

struct Command {
  std::uint32_t cmd = 0;
  std::string bytes;           // the whole load command
  std::uint32_t path_off = 0;  // lc_str offset for dylib and rpath commands, else 0

  [[nodiscard]] auto Path() const -> std::string {
    if (path_off == 0) {
      return {};
    }
    const size_t end = bytes.find('\0', path_off);
    return bytes.substr(path_off, end == std::string::npos ? std::string::npos : end - path_off);
  }

  // NUL terminated, cmdsize stays a multiple of 8
  void SetPath(std::string_view path) {
    constexpr size_t kAlign = 8;
    bytes.resize(path_off);
    bytes += path;
    bytes.resize((bytes.size() + kAlign) / kAlign * kAlign, '\0');
    BinaryImage image(std::move(bytes));
    image.Write(4, static_cast<std::uint32_t>(image.bytes().size()));
    bytes = image.bytes();
  }
};

auto IsPathCommand(std::uint32_t cmd) -> bool {
  return cmd == kLoadDylib || cmd == kLoadWeakDylib || cmd == kReexportDylib || cmd == kLoadUpwardDylib ||
         cmd == kIdDylib || cmd == kRpath;
}

struct LoadCommands {
  std::vector<Command> commands;
  std::uint64_t room = 0;  // bytes from the end of the header to the first segment's file content
};

auto ReadLoadCommands(const BinaryImage& image, const MachHeader64& header) -> LoadCommands {
  LoadCommands out;
  out.room = image.bytes().size() - sizeof(MachHeader64);
  std::uint64_t offset = sizeof(MachHeader64);
  for (std::uint32_t i = 0; i < header.ncmds; ++i) {
    const std::optional<LoadCommand> load = image.Read<LoadCommand>(offset);
    if (!load || load->cmdsize < sizeof(LoadCommand) || offset + load->cmdsize > image.bytes().size()) {
      break;
    }
    Command command{.cmd = load->cmd, .bytes = image.bytes().substr(offset, load->cmdsize)};
    if (IsPathCommand(load->cmd)) {
      // dylib_command and rpath_command both start cmd, cmdsize, then the string's lc_str offset
      const std::uint32_t path_off = image.Read<std::uint32_t>(offset + sizeof(LoadCommand)).value_or(0);
      command.path_off = path_off < load->cmdsize ? path_off : 0;
    }
    if (load->cmd == kSegment64) {
      // segment_command_64: fileoff at 40, filesize at 48. The first with content bounds the header
      const std::uint64_t fileoff = image.Read<std::uint64_t>(offset + 40).value_or(0);
      const std::uint64_t filesize = image.Read<std::uint64_t>(offset + 48).value_or(0);
      if (filesize != 0 && fileoff == 0) {
        // __TEXT maps the header itself: its first section's offset is the bound (section_64
        // records follow at 72, 80 bytes each, offset field at 48)
        const std::uint32_t nsects = image.Read<std::uint32_t>(offset + 64).value_or(0);
        for (std::uint32_t sect = 0; sect < nsects; ++sect) {
          const std::uint32_t sect_off = image.Read<std::uint32_t>(offset + 72 + (sect * 80ULL) + 48).value_or(0);
          if (sect_off != 0) {
            out.room = std::min<std::uint64_t>(out.room, sect_off - sizeof(MachHeader64));
          }
        }
      } else if (filesize != 0) {
        out.room = std::min<std::uint64_t>(out.room, fileoff - sizeof(MachHeader64));
      }
    }
    out.commands.push_back(std::move(command));
    offset += load->cmdsize;
  }
  return out;
}

auto Big32(const BinaryImage& image, std::uint64_t offset) -> std::optional<std::uint32_t> {
  const std::optional<std::uint32_t> raw = image.Read<std::uint32_t>(offset);
  if (!raw) {
    return std::nullopt;
  }
  return std::byteswap(*raw);  // code signing blobs are big endian
}

// ld's ad-hoc signature hashes the file page by page: bytes changed, the hashes must follow or
// the kernel kills the process. Blob layout per xnu's cs_blobs.h, SHA-256 only (what ld64 and lld
// emit for arm64)
auto Resign(BinaryImage& image, std::string_view shown) -> bool {
  constexpr std::uint32_t kEmbeddedSignature = 0xfade0cc0;
  constexpr std::uint32_t kCodeDirectory = 0xfade0c02;
  constexpr std::uint8_t kSha256 = 2;
  constexpr std::uint32_t kHashOffsetField = 16;
  constexpr std::uint32_t kCodeSlotsField = 28;
  constexpr std::uint32_t kCodeLimitField = 32;
  constexpr std::uint32_t kHashSizeField = 36;
  constexpr std::uint32_t kHashTypeField = 37;
  constexpr std::uint32_t kPageSizeField = 39;
  const std::optional<MachHeader64> header = image.Read<MachHeader64>(0);
  std::uint64_t offset = sizeof(MachHeader64);
  std::optional<std::uint32_t> sig_off;
  for (std::uint32_t i = 0; header && i < header->ncmds; ++i) {
    const std::optional<LoadCommand> load = image.Read<LoadCommand>(offset);
    if (!load || load->cmdsize < sizeof(LoadCommand)) {
      break;
    }
    if (load->cmd == kCodeSignature) {
      sig_off = image.Read<std::uint32_t>(offset + sizeof(LoadCommand));  // linkedit_data_command.dataoff
    }
    offset += load->cmdsize;
  }
  if (!sig_off) {
    return true;  // unsigned (x86_64 default): nothing to keep in sync
  }
  if (Big32(image, *sig_off) != kEmbeddedSignature) {
    std::println(stderr, "reloc-fixup: {}: LC_CODE_SIGNATURE is no embedded signature blob", shown);
    return false;
  }
  const std::uint32_t blobs = Big32(image, *sig_off + 8).value_or(0);
  for (std::uint32_t i = 0; i < blobs; ++i) {
    const std::uint64_t dir = *sig_off + Big32(image, *sig_off + 12 + (std::uint64_t{i} * 8) + 4).value_or(0);
    if (Big32(image, dir) != kCodeDirectory) {
      continue;
    }
    const std::uint32_t hash_off = Big32(image, dir + kHashOffsetField).value_or(0);
    const std::uint32_t slots = Big32(image, dir + kCodeSlotsField).value_or(0);
    const std::uint32_t limit = Big32(image, dir + kCodeLimitField).value_or(0);
    const std::uint8_t hash_size = image.Read<std::uint8_t>(dir + kHashSizeField).value_or(0);
    const std::uint8_t hash_type = image.Read<std::uint8_t>(dir + kHashTypeField).value_or(0);
    const std::size_t page = std::size_t{1} << image.Read<std::uint8_t>(dir + kPageSizeField).value_or(0);
    if (hash_type != kSha256 || hash_size != kSha256Size) {
      std::println(stderr, "reloc-fixup: {}: code signature hash type {} is not SHA-256", shown, hash_type);
      return false;
    }
    for (std::uint32_t slot = 0; slot < slots; ++slot) {
      const std::size_t begin = std::size_t{slot} * page;
      const std::size_t end = std::min<std::size_t>(begin + page, limit);
      const std::string digest = Sha256(std::string_view(image.bytes()).substr(begin, end - begin));
      if (!image.Overwrite(dir + hash_off + (std::uint64_t{slot} * hash_size), digest)) {
        std::println(stderr, "reloc-fixup: {}: code signature slot {} lies outside the file", shown, slot);
        return false;
      }
    }
  }
  return true;
}

auto IsSystemPath(std::string_view path) -> bool {
  return path.starts_with("/usr/lib/") || path.starts_with("/System/");
}

// Where a load command points once the tree is at dest, nullopt when dyld would not find it
auto Resolve(const FixupContext& ctx, const fs::path& here, const std::string& path) -> std::optional<fs::path> {
  std::error_code error;
  if (IsSystemPath(path)) {
    // the SDK lists what the OS ships: libz.1.dylib as libz.1.tbd, Foo.framework/Foo as Foo.tbd
    const std::string stem = path.ends_with(".dylib") ? path.substr(0, path.size() - 6) : path;
    const bool known = ctx.sdk.empty() || fs::exists(ctx.sdk / (stem.substr(1) + ".tbd"), error);
    return known ? std::optional(fs::path(path)) : std::nullopt;
  }
  std::optional<fs::path> target;
  constexpr std::string_view kRpath = "@rpath/";
  constexpr std::string_view kLoader = "@loader_path/";
  if (path.starts_with(kRpath)) {
    // only our own: a dependency's id is absolute (below), so nothing else says @rpath
    for (const fs::path& dir : ctx.own_lib_dirs) {
      if (!target && fs::exists(dir / path.substr(kRpath.size()), error)) {
        target = ctx.Final(dir / path.substr(kRpath.size()));
      }
    }
  } else if (path.starts_with(kLoader)) {
    target = (here / path.substr(kLoader.size())).lexically_normal();
  } else if (Store::Get().IsStorePath(ctx.Final(path).string())) {
    target = ctx.Final(path);
  }
  // ours must exist, a dependency's store path does or the linker had not found it
  if (target && ctx.OnDisk(*target) != *target && !fs::exists(ctx.OnDisk(*target), error)) {
    target.reset();
  }
  return target;
}

// What a path command should say for the tree to relocate, nullopt to leave it:
//   LC_ID_DYLIB    the file's own final path, so dependents record a store path, never @rpath
//   LC_LOAD_DYLIB  @loader_path/relative to where it resolves (the reference Nix sees, no
//                  search), system libraries verbatim. Unresolvable is an error
//   LC_RPATH       store paths @loader_path/relative, the rest left (nothing of ours needs them)
auto NewSpelling(FixupContext& ctx, const fs::path& self, const Command& command, std::string_view shown)
    -> std::optional<std::string> {
  const std::string path = command.Path();
  const fs::path here = self.parent_path();
  if (command.cmd == kIdDylib) {
    return self.string();
  }
  if (command.cmd == kRpath) {
    const fs::path target = ctx.Final(path);
    return Store::Get().IsStorePath(target.string()) ? std::optional(RelativeTo(here, target, "@loader_path"))
                                                     : std::nullopt;
  }
  const std::optional<fs::path> target = Resolve(ctx, here, path);
  if (!target) {
    std::println(stderr, "reloc-fixup: {}: links {}, which neither the package, a dependency nor the SDK has", shown,
                 path);
    ++ctx.errors;
    return std::nullopt;
  }
  return IsSystemPath(path) ? path : RelativeTo(here, *target, "@loader_path");
}

}  // namespace

auto FixMachO(FixupContext& ctx, const fs::path& path, BinaryImage& image) -> bool {
  const std::optional<MachHeader64> header = image.Read<MachHeader64>(0);
  if (!header || header->magic != kMagic64) {
    return false;
  }
  const fs::path self = ctx.Final(path);
  const std::string shown = fs::relative(path, ctx.prefix).string();
  LoadCommands table = ReadLoadCommands(image, *header);

  std::vector<std::string> log{shown};
  for (Command& command : table.commands) {
    if (command.path_off == 0) {
      continue;
    }
    if (const std::optional<std::string> text = NewSpelling(ctx, self, command, shown);
        text && *text != command.Path()) {
      command.SetPath(*text);
      log.push_back(*text);
    }
  }
  if (log.size() == 1) {
    return true;
  }

  std::string cmds;
  for (const Command& command : table.commands) {
    cmds += command.bytes;
  }
  if (cmds.size() > table.room) {
    std::println(stderr, "reloc-fixup: {}: load commands need {} bytes, the header has room for {} (-headerpad)", shown,
                 cmds.size(), table.room);
    ++ctx.errors;
    return true;
  }
  image.Write(offsetof(MachHeader64, sizeofcmds), static_cast<std::uint32_t>(cmds.size()));
  cmds.resize(table.room, '\0');
  image.Overwrite(sizeof(MachHeader64), cmds);

  if (!Resign(image, shown)) {
    ++ctx.errors;
    return true;
  }
  if (!WriteBack(path, image.bytes())) {
    ++ctx.errors;
    return true;
  }
  std::println("{}", Join(log, "  "));
  return true;
}

}  // namespace jig
