// reloc-fixup mode (argv[0] = reloc-fixup): `reloc-fixup <prefix>` rewrites every ELF64-LE file
// under <prefix> in place so the tree is relocatable:
//   - RUNPATH: store entries -> $ORIGIN-relative, padding/build/host entries dropped, a NEEDED
//     library found nowhere on the RUNPATH but inside <prefix> gets its dir prepended
//   - PT_INTERP (when the crt_interp stub is linked, i.e. __reloc_start is exported): store path
//     -> prefix-relative, segment type -> PT_NULL, e_entry -> __reloc_start
// Exit status 1 if any file could not be made consistent (unresolvable NEEDED, no slack).
#ifndef PKGS_CC_FIXUP_MODE_H_
#define PKGS_CC_FIXUP_MODE_H_

#include <cstdint>
#include <cstring>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <type_traits>

namespace jig {

auto RunFixupMode(std::span<const std::string> args) -> int;

// Bounds-checked view of an ELF image held in a std::string. Exposed for tests.
class ElfImage {
 public:
  explicit ElfImage(std::string bytes) : bytes_(std::move(bytes)) {}
  [[nodiscard]] auto bytes() const -> const std::string& { return bytes_; }
  [[nodiscard]] auto IsElf64LittleEndian() const -> bool;

  template <typename T>
    requires std::is_trivially_copyable_v<T>
  [[nodiscard]] auto Read(std::uint64_t offset) const -> std::optional<T> {
    if (offset > bytes_.size() || bytes_.size() - offset < sizeof(T)) {
      return std::nullopt;
    }
    T value{};
    std::memcpy(&value, &bytes_.at(offset), sizeof(T));
    return value;
  }
  template <typename T>
    requires std::is_trivially_copyable_v<T>
  auto Write(std::uint64_t offset, const T& value) -> bool {
    if (offset > bytes_.size() || bytes_.size() - offset < sizeof(T)) {
      return false;
    }
    std::memcpy(&bytes_.at(offset), &value, sizeof(T));
    return true;
  }
  // NUL-terminated string at offset, "" if out of range
  [[nodiscard]] auto CString(std::uint64_t offset) const -> std::string;
  // overwrite [offset, offset+capacity) with text + NUL padding. Returns false if it does not fit
  auto WritePadded(std::uint64_t offset, std::uint64_t capacity, std::string_view text) -> bool;

 private:
  std::string bytes_;
};

}  // namespace jig

#endif  // PKGS_CC_FIXUP_MODE_H_
