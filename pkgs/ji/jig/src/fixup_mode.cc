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
#include <string_view>
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

// one RUNPATH element: its text, the directory it denotes, whether ld.so must still search it
struct RunpathDir {
  std::string entry;
  fs::path dir;
  bool keep = true;
  // the dynamic linker's own directory: what lives there is NEEDED by soname everywhere
  [[nodiscard]] auto IsLibc() const -> bool { return fs::exists(dir / "libc.so.6"); }
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

// ld.so matches a DT_VERNEED entry to the loaded object by string equality with the DT_NEEDED
// it was loaded under, so when NEEDED becomes a path vn_file must name the same string
struct Needed {
  std::string name;
  std::uint64_t val_offset = 0;         // file offset of this entry's d_un.d_val
  std::vector<std::uint64_t> vn_files;  // file offsets of Elf64_Verneed.vn_file naming it (Elf64_Word)
};

struct DynamicInfo {
  std::vector<Needed> needed;
  std::uint64_t dynstr = 0;                     // file offset of the dynamic string table
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
  info.dynstr = dynstr.offset;
  for (std::uint64_t off = dynamic->offset; off < SectionEnd(elf, *dynamic); off += sizeof(Elf64_Dyn)) {
    const auto dyn = elf.Read<Elf64_Dyn>(off);
    if (!dyn || dyn->d_tag == DT_NULL) {
      break;
    }
    // NOLINTBEGIN(cppcoreguidelines-pro-type-union-access): Elf64_Dyn is defined with a union
    if (dyn->d_tag == DT_NEEDED) {
      info.needed.push_back({
          .name = elf.CString(dynstr.offset + dyn->d_un.d_val),
          .val_offset = off + offsetof(Elf64_Dyn, d_un),
          .vn_files = {},
      });
    }
    if (dyn->d_tag == DT_RUNPATH || dyn->d_tag == DT_RPATH) {
      info.runpath_offset = dynstr.offset + dyn->d_un.d_val;
    }
    // NOLINTEND(cppcoreguidelines-pro-type-union-access)
  }
  const auto verneed =
      std::ranges::find_if(sections, [](const Section& section) -> bool { return section.type == SHT_GNU_verneed; });
  for (std::uint64_t off = verneed == sections.end() ? 0 : verneed->offset; off != 0;) {
    const auto ent = elf.Read<Elf64_Verneed>(off);
    if (!ent) {
      break;
    }
    const std::string file = elf.CString(dynstr.offset + ent->vn_file);
    for (Needed& lib : info.needed) {
      if (lib.name == file) {
        lib.vn_files.push_back(off + offsetof(Elf64_Verneed, vn_file));
      }
    }
    off = ent->vn_next == 0 ? 0 : off + ent->vn_next;
  }
  return info;
}

// GNU ld suffix-merges .dynstr, so a symbol name could be the tail of the RUNPATH string and
// rewriting it would rename the symbol. lld only merges identical strings. Refuse, do not corrupt
auto SymbolInside(const ElfImage& elf, const std::vector<Section>& sections, std::uint64_t begin, std::uint64_t end)
    -> std::optional<std::string> {
  const auto dynsym =
      std::ranges::find_if(sections, [](const Section& section) -> bool { return section.type == SHT_DYNSYM; });
  if (dynsym == sections.end() || dynsym->entsize < sizeof(Elf64_Sym) || dynsym->link >= sections.size()) {
    return std::nullopt;
  }
  const std::uint64_t strtab = sections.at(dynsym->link).offset;
  for (std::uint64_t off = dynsym->offset; off < SectionEnd(elf, *dynsym); off += dynsym->entsize) {
    const auto sym = elf.Read<Elf64_Sym>(off);
    if (sym && strtab + sym->st_name > begin && strtab + sym->st_name < end) {
      return elf.CString(strtab + sym->st_name);
    }
  }
  return std::nullopt;
}

// the existing RUNPATH with store entries made $ORIGIN-relative, then this package's own lib dirs
// (a NEEDED sibling the build system gave no rpath for). Padding, build and host dirs drop out
auto RelativizeRunpath(const FixupContext& ctx, const std::string& old, const fs::path& here)
    -> std::vector<RunpathDir> {
  constexpr std::string_view kOriginPrefix = "$ORIGIN/";
  const Store& store = Store::Get();
  std::vector<RunpathDir> runpath;
  for (const std::string& entry : Split(old, ':')) {
    if (store.IsStorePath(entry)) {
      runpath.push_back({.entry = "$ORIGIN/" + RelativeFrom(here, entry), .dir = fs::path(entry).lexically_normal()});
    } else if (entry == "$ORIGIN") {
      runpath.push_back({.entry = entry, .dir = here});
    } else if (entry.starts_with(kOriginPrefix)) {
      runpath.push_back({.entry = entry, .dir = (here / entry.substr(kOriginPrefix.size())).lexically_normal()});
    }
  }
  for (const fs::path& own : ctx.own_lib_dirs) {
    runpath.push_back(
        {.entry = own == here ? "$ORIGIN" : "$ORIGIN/" + RelativeFrom(here, own), .dir = own, .keep = false});
  }
  return runpath;
}

auto RenderRunpath(const std::vector<RunpathDir>& runpath) -> std::string {
  std::vector<std::string> kept;
  for (const RunpathDir& dir : runpath) {
    if (dir.keep && !std::ranges::contains(kept, dir.entry)) {
      kept.push_back(dir.entry);
    }
  }
  return Join(kept, ":");
}

// Returns false on an unrecoverable inconsistency (already reported). Every NEEDED that a RUNPATH
// dir provides becomes "$ORIGIN/<rel>/<soname>": ld.so expands $ORIGIN in DT_NEEDED and opens a
// name with a slash directly, no directory search. The strings go where the padded RUNPATH was.
// A dir leaves RUNPATH once its NEEDED are direct; libc's stays (its objects are NEEDED by soname
// so an already mapped libc matches by name) and so do dirs that served no NEEDED: dlopen's.
// If the slack does not suffice the NEEDED stay sonames and their dirs on RUNPATH
auto FixRunpath(FixupContext& ctx, const fs::path& path, ElfImage& elf, const std::vector<Section>& sections,
                std::vector<std::string>& log, bool& dirty) -> bool {
  const DynamicInfo dynamic = ReadDynamic(elf, sections);
  if (!dynamic.runpath_offset) {
    return true;
  }
  const std::uint64_t runpath_offset = *dynamic.runpath_offset;
  const std::string old = elf.CString(runpath_offset);
  std::vector<RunpathDir> runpath = RelativizeRunpath(ctx, old, path.parent_path());
  std::vector<std::pair<const Needed*, RunpathDir*>> direct;
  for (const Needed& lib : dynamic.needed) {
    if (lib.name.contains('/') || lib.name.starts_with("ld-linux") || lib.name.starts_with("linux-vdso")) {
      continue;
    }
    const auto dir =
        std::ranges::find_if(runpath, [&](const RunpathDir& rpd) -> bool { return fs::exists(rpd.dir / lib.name); });
    if (dir == runpath.end()) {
      std::println(stderr, "{}: NEEDED {} not found in RUNPATH [{}] nor under {}", path.string(), lib.name, old,
                   ctx.prefix.string());
      ++ctx.errors;
      continue;
    }
    if (!dir->IsLibc()) {
      dir->keep = false;
      direct.emplace_back(&lib, &*dir);
    }
  }
  const auto target = [](const auto& dep) -> std::string { return dep.second->entry + "/" + dep.first->name; };
  std::string neu = RenderRunpath(runpath);
  std::string blob = neu;
  for (const auto& dep : direct) {
    blob.append(1, '\0').append(target(dep));
  }
  if (blob.size() > old.size()) {
    for (const auto& dep : direct) {
      dep.second->keep = true;
    }
    direct.clear();
    neu = blob = RenderRunpath(runpath);
  }
  if (blob != old) {
    if (const auto sym = SymbolInside(elf, sections, runpath_offset, runpath_offset + old.size())) {
      std::println(stderr, "{}: symbol '{}' shares bytes with RUNPATH (suffix-merged .dynstr, not lld?)", path.string(),
                   *sym);
      ++ctx.errors;
      return false;
    }
    if (!elf.WritePadded(runpath_offset, old.size(), blob)) {
      std::println(stderr, "{}: RUNPATH does not fit ({} > {}): {}", path.string(), blob.size(), old.size(), neu);
      ++ctx.errors;
      return false;
    }
    std::uint64_t str = runpath_offset + neu.size() + 1 - dynamic.dynstr;
    for (const auto& dep : direct) {
      elf.Write<std::uint64_t>(dep.first->val_offset, str);
      for (const std::uint64_t vn_file : dep.first->vn_files) {
        elf.Write<std::uint32_t>(vn_file, static_cast<std::uint32_t>(str));
      }
      str += target(dep).size() + 1;
    }
    dirty = true;
  }
  log.push_back("RUNPATH " + neu);
  for (const auto& dep : direct) {
    log.push_back("NEEDED " + target(dep));
  }
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
