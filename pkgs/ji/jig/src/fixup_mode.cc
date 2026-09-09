#include "fixup_mode.h"

#include <elf.h>
#include <sys/stat.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <format>
#include <optional>
#include <print>
#include <set>
#include <span>
#include <system_error>
#include <utility>
#include <vector>

#include "base.h"
#include "store.h"

namespace jig {

namespace {

namespace fs = std::filesystem;

constexpr size_t kLeakContext = 100;  // bytes of a leaked store path shown in the warning

struct Section {
  std::uint32_t type = 0;
  std::uint64_t offset = 0;
  std::uint64_t size = 0;
  std::uint32_t link = 0;
  std::uint64_t entsize = 0;
};

// end of a section's file range clamped to the image: a corrupt sh_offset/sh_size can neither
// overflow nor make the entry loops spin (reads past the end are nullopt anyway)
auto SectionEnd(const ElfImage& elf, const Section& section) -> std::uint64_t {
  const std::uint64_t size = elf.bytes().size();
  if (section.offset >= size) {
    return 0;
  }
  return section.offset + std::min(section.size, size - section.offset);
}

auto RelativeFrom(const fs::path& dir, const fs::path& target) -> std::string {
  return target.lexically_normal().lexically_relative(dir).string();
}

struct FixupContext {
  fs::path prefix;
  std::vector<fs::path> own_lib_dirs;  // dirs under prefix that contain shared objects
  int errors = 0;
};

// RUNPATH being rebuilt: entry text plus the directory it denotes, for NEEDED lookups.
class Runpath {
 public:
  void Append(std::string entry, fs::path dir) { Insert(entries_.size(), std::move(entry), std::move(dir)); }
  void Prepend(std::string entry, fs::path dir) { Insert(0, std::move(entry), std::move(dir)); }
  [[nodiscard]] auto Provides(const std::string& lib) const -> bool {
    return std::ranges::any_of(dirs_, [&](const fs::path& dir) -> bool { return fs::exists(dir / lib); });
  }
  [[nodiscard]] auto Render() const -> std::string { return Join(entries_, ":"); }

 private:
  void Insert(size_t index, std::string entry, fs::path dir) {
    if (std::ranges::contains(entries_, entry)) {
      return;
    }
    entries_.insert(entries_.begin() + static_cast<std::ptrdiff_t>(index), std::move(entry));
    dirs_.insert(dirs_.begin() + static_cast<std::ptrdiff_t>(index), std::move(dir));
  }
  std::vector<std::string> entries_;
  std::vector<fs::path> dirs_;
};

auto ReadSections(const ElfImage& elf, const Elf64_Ehdr& ehdr) -> std::vector<Section> {
  std::vector<Section> sections;
  for (unsigned i = 0; i < ehdr.e_shnum; ++i) {
    const auto shdr = elf.Read<Elf64_Shdr>(ehdr.e_shoff + (std::uint64_t{i} * ehdr.e_shentsize));
    if (!shdr) {
      break;
    }
    sections.push_back({
        .type = shdr->sh_type,
        .offset = shdr->sh_offset,
        .size = shdr->sh_size,
        .link = shdr->sh_link,
        .entsize = shdr->sh_entsize,
    });
  }
  return sections;
}

struct DynamicInfo {
  std::vector<std::string> needed;
  std::optional<std::uint64_t> runpath_offset;  // file offset of the RUNPATH string
};

auto ReadDynamic(const ElfImage& elf, const std::vector<Section>& sections) -> DynamicInfo {
  DynamicInfo info;
  const auto dynamic =
      std::ranges::find_if(sections, [](const Section& section) -> bool { return section.type == SHT_DYNAMIC; });
  if (dynamic == sections.end() || dynamic->link >= sections.size() || sections.at(dynamic->link).type == SHT_NOBITS) {
    return info;
  }
  const Section& dynstr = sections.at(dynamic->link);
  for (std::uint64_t off = dynamic->offset; off < SectionEnd(elf, *dynamic); off += sizeof(Elf64_Dyn)) {
    const auto dyn = elf.Read<Elf64_Dyn>(off);
    if (!dyn || dyn->d_tag == DT_NULL) {
      break;
    }
    // NOLINTBEGIN(cppcoreguidelines-pro-type-union-access): Elf64_Dyn is defined with a union
    if (dyn->d_tag == DT_NEEDED) {
      info.needed.push_back(elf.CString(dynstr.offset + dyn->d_un.d_val));
    }
    if (dyn->d_tag == DT_RUNPATH || dyn->d_tag == DT_RPATH) {
      info.runpath_offset = dynstr.offset + dyn->d_un.d_val;
    }
    // NOLINTEND(cppcoreguidelines-pro-type-union-access)
  }
  return info;
}

// the existing RUNPATH with store entries made $ORIGIN-relative. Padding, build and host dirs drop out
auto RelativizeRunpath(const std::string& old, const fs::path& here) -> Runpath {
  constexpr std::string_view kOriginPrefix = "$ORIGIN/";
  const Store& store = Store::Get();
  Runpath runpath;
  for (const std::string& entry : Split(old, ':')) {
    if (store.IsStorePath(entry)) {
      runpath.Append("$ORIGIN/" + RelativeFrom(here, entry), fs::path(entry).lexically_normal());
    } else if (entry == "$ORIGIN") {
      runpath.Append(entry, here);
    } else if (entry.starts_with(kOriginPrefix)) {
      runpath.Append(entry, (here / entry.substr(kOriginPrefix.size())).lexically_normal());
    }
  }
  return runpath;
}

// Returns false on an unrecoverable inconsistency (already reported).
auto FixRunpath(FixupContext& ctx, const fs::path& path, ElfImage& elf, const std::vector<Section>& sections,
                std::vector<std::string>& log, bool& dirty) -> bool {
  const DynamicInfo dynamic = ReadDynamic(elf, sections);
  if (!dynamic.runpath_offset) {
    return true;
  }
  const std::uint64_t runpath_offset = *dynamic.runpath_offset;
  const fs::path here = path.parent_path();
  const std::string old = elf.CString(runpath_offset);
  Runpath runpath = RelativizeRunpath(old, here);
  for (const std::string& lib : dynamic.needed) {
    if (lib.starts_with("ld-linux") || lib.starts_with("linux-vdso") || runpath.Provides(lib)) {
      continue;
    }
    const auto own =
        std::ranges::find_if(ctx.own_lib_dirs, [&](const fs::path& dir) -> bool { return fs::exists(dir / lib); });
    if (own == ctx.own_lib_dirs.end()) {
      std::println(stderr, "{}: NEEDED {} not found in RUNPATH [{}] nor under {}", path.string(), lib, old,
                   ctx.prefix.string());
      ++ctx.errors;
      continue;
    }
    runpath.Prepend(*own == here ? "$ORIGIN" : "$ORIGIN/" + RelativeFrom(here, *own), *own);
  }
  const std::string neu = runpath.Render();
  if (neu != old) {
    if (!elf.WritePadded(runpath_offset, old.size(), neu)) {
      std::println(stderr, "{}: RUNPATH does not fit ({} > {}): {}", path.string(), neu.size(), old.size(), neu);
      ++ctx.errors;
      return false;
    }
    dirty = true;
  }
  log.push_back("RUNPATH " + neu);
  return true;
}

constexpr std::string_view kRelocStubMagic = "RELOCSTB";  // struct StubHeader in crt_interp.c
constexpr std::uint64_t kRelocStubHeader = 16;

// vaddr -> file offset through the PT_LOADs
auto FileOffset(const ElfImage& elf, const Elf64_Ehdr& ehdr, std::uint64_t vaddr) -> std::optional<std::uint64_t> {
  for (unsigned i = 0; i < ehdr.e_phnum; ++i) {
    const auto phdr = elf.Read<Elf64_Phdr>(ehdr.e_phoff + (std::uint64_t{i} * ehdr.e_phentsize));
    if (phdr && phdr->p_type == PT_LOAD && vaddr >= phdr->p_vaddr && vaddr - phdr->p_vaddr < phdr->p_filesz) {
      return phdr->p_offset + (vaddr - phdr->p_vaddr);
    }
  }
  return std::nullopt;
}

// The stub's entry: __reloc_start exported by our link (crt_interp.o), or e_entry itself when it
// points just past a RELOCSTB header (reloc_stub.bin installed by `formatelf --set-entry-stub`).
auto FindRelocStart(const ElfImage& elf, const Elf64_Ehdr& ehdr, const std::vector<Section>& sections)
    -> std::optional<std::uint64_t> {
  if (ehdr.e_entry >= kRelocStubHeader) {
    const std::optional<std::uint64_t> off = FileOffset(elf, ehdr, ehdr.e_entry - kRelocStubHeader);
    if (off && std::string_view(elf.bytes()).substr(*off, kRelocStubMagic.size()) == kRelocStubMagic) {
      return ehdr.e_entry;
    }
  }
  const auto dynsym =
      std::ranges::find_if(sections, [](const Section& section) -> bool { return section.type == SHT_DYNSYM; });
  if (dynsym == sections.end() || dynsym->entsize < sizeof(Elf64_Sym) || dynsym->link >= sections.size()) {
    return std::nullopt;
  }
  const Section& strtab = sections.at(dynsym->link);
  for (std::uint64_t off = dynsym->offset; off < SectionEnd(elf, *dynsym); off += dynsym->entsize) {
    const auto sym = elf.Read<Elf64_Sym>(off);
    if (!sym) {
      break;
    }
    if (elf.CString(strtab.offset + sym->st_name) == "__reloc_start") {
      return sym->st_value;
    }
  }
  return std::nullopt;
}

auto FixInterp(FixupContext& ctx, const fs::path& path, ElfImage& elf, const Elf64_Ehdr& ehdr,
               const std::vector<Section>& sections, std::vector<std::string>& log, bool& dirty) -> bool {
  const Store& store = Store::Get();
  const std::optional<std::uint64_t> stub = FindRelocStart(elf, ehdr, sections);
  for (unsigned i = 0; i < ehdr.e_phnum; ++i) {
    const std::uint64_t ph_off = ehdr.e_phoff + (std::uint64_t{i} * ehdr.e_phentsize);
    std::optional<Elf64_Phdr> phdr = elf.Read<Elf64_Phdr>(ph_off);
    if (!phdr) {
      break;
    }
    if (phdr->p_type != PT_INTERP) {
      continue;
    }
    const std::uint64_t ioff = phdr->p_offset;
    const std::uint64_t isz = phdr->p_filesz;
    const std::string old = elf.CString(ioff);
    if (!stub) {
      log.push_back("INTERP " + old + " kept (no stub)");
      continue;
    }
    std::string neu = old;
    if (store.IsStorePath(old)) {
      neu = RelativeFrom(path.parent_path(), old);
      if (!elf.WritePadded(ioff, isz, neu)) {
        std::println(stderr, "{}: interp does not fit: {}", path.string(), neu);
        ++ctx.errors;
        return false;
      }
    }
    phdr->p_type = PT_NULL;
    elf.Write(ph_off, *phdr);
    Elf64_Ehdr new_eh = ehdr;
    new_eh.e_entry = *stub;
    elf.Write(std::uint64_t{0}, new_eh);
    dirty = true;
    log.push_back("INTERP " + neu + " (PT_NULL, entry=__reloc_start)");
  }
  return true;
}

void FixOne(FixupContext& ctx, const fs::path& path) {
  if (path.extension() == ".debug") {
    return;
  }
  std::optional<std::string> data = ReadFile(path);
  if (!data) {
    return;
  }
  ElfImage elf(std::move(*data));
  if (!elf.IsElf64LittleEndian()) {
    return;
  }
  const std::optional<Elf64_Ehdr> ehdr = elf.Read<Elf64_Ehdr>(0);
  if (!ehdr || (ehdr->e_type != ET_EXEC && ehdr->e_type != ET_DYN)) {
    return;
  }

  const std::vector<Section> sections = ReadSections(elf, *ehdr);
  std::vector<std::string> log{fs::relative(path, ctx.prefix).string()};
  bool dirty = false;
  if (!FixRunpath(ctx, path, elf, sections, log, dirty)) {
    return;
  }
  if (!FixInterp(ctx, path, elf, *ehdr, sections, log, dirty)) {
    return;
  }

  if (dirty) {
    struct stat status{};
    const bool have_mode = ::stat(path.c_str(), &status) == 0;
    if (have_mode) {
      ::chmod(path.c_str(), status.st_mode | S_IWUSR);
    }
    WriteFile(path, elf.bytes());
    if (have_mode) {
      ::chmod(path.c_str(), status.st_mode);
    }
    std::println("{}", Join(log, "  "));
  }
  if (const size_t leak = elf.bytes().find(Store::Get().dir() + "/"); leak != std::string::npos) {
    std::println("  WARN absolute store ref in {} @{:#x}: {}", fs::relative(path, ctx.prefix).string(), leak,
                 elf.CString(leak).substr(0, kLeakContext));
  }
}

}  // namespace

auto ElfImage::IsElf64LittleEndian() const -> bool {
  return bytes_.starts_with(std::string_view(ELFMAG, SELFMAG)) && bytes_.size() > EI_DATA &&
         bytes_.at(EI_CLASS) == ELFCLASS64 && bytes_.at(EI_DATA) == ELFDATA2LSB;
}

auto ElfImage::CString(std::uint64_t offset) const -> std::string {
  if (offset >= bytes_.size()) {
    return {};
  }
  const size_t end = bytes_.find('\0', offset);
  return bytes_.substr(offset, end == std::string::npos ? std::string::npos : end - offset);
}

auto ElfImage::WritePadded(std::uint64_t offset, std::uint64_t capacity, std::string_view text) -> bool {
  if (text.size() + 1 > capacity || offset > bytes_.size() || bytes_.size() - offset < capacity) {
    return false;
  }
  bytes_.replace(offset, capacity, std::string(text) + std::string(capacity - text.size(), '\0'));
  return true;
}

auto RunFixupMode(std::span<const std::string> args) -> int {
  if (args.empty()) {
    std::println(stderr, "usage: reloc-fixup <prefix>");
    return 2;
  }
  FixupContext ctx{.prefix = fs::path(args.front()).lexically_normal(), .own_lib_dirs = {}, .errors = 0};
  if (!Store::Get().IsStorePath(ctx.prefix.string())) {
    std::println(stderr, "reloc-fixup: {} is not under {}", ctx.prefix.string(), Store::Get().dir());
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
    if (name.contains(".so") && !entry.path().parent_path().string().contains("/debug")) {
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
