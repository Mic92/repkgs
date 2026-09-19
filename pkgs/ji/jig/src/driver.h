// Driver mode configuration and link policy: what turns `cc <user args>` into the real clang
// command line. etc/jig.json next to the binary (pkgs/ll/llvm/cc.nu writes it), a JSON object:
//   cc          /path/to/real/clang: compiler to exec
//   fc, fflags  the Fortran compiler and its flags, used when invoked as gfortran/flang/fortran
//   binfmt      elf | macho | coff
//   flags       [..] prepended to every invocation
//   cxxflags    [..] prepended when invoked under a "++" name
//   libc        <libc prefix>: always an rpath entry, holds the dynamic linker
//   interp      dynamic linker basename
//   crt         optional: the $ORIGIN-interp stub linked into executables
//   runtimes    libc++/libunwind dir, rpath'd whenever C++ or an unwinder is linked
//   prefix-map  [..] -ffile-prefix-map entries (plus $PKGS_PREFIX_MAP at run time)
// and per package, from $PKGS_CC at run time: cflags/cxxflags/ldflags after the conf's, before argv.
// Without a conf, $JIG_CC names the compiler and user args pass through untouched (cache only).
#pragma once

#include <cstdint>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "keys.h"

namespace jig {

// Slack reserved at link time so reloc-fixup can rewrite in place:
inline constexpr int kRunpathSlack = 48;  // pad bytes per RUNPATH entry (abs -> $ORIGIN-relative)
inline constexpr int kNeededSlack = 80;   // pad bytes per -l ($ORIGIN/../../<hash>-x/lib/libx.so.N)
inline constexpr int kInterpSlack = 12;   // "./" pairs in front of the interp basename

struct PackageCcFlags {
  std::vector<std::string> cflags;    // every compile and link
  std::vector<std::string> cxxflags;  // C++ only
  std::vector<std::string> ldflags;   // link steps only, after argv
};

// The link policy (interp, RUNPATH) and lld's --dependency-file exist for ELF only.
enum class BinFmt : std::uint8_t { kElf, kMachO, kCoff };

struct DriverConf {
  std::string cc;
  std::string fc;  // flang, run under the fortran names with fflags in place of flags
  BinFmt binfmt = BinFmt::kElf;
  std::string libc;
  std::string interp = "ld-linux-x86-64.so.2";
  std::string crt;
  std::string runtimes;
  std::vector<std::string> flags;
  std::vector<std::string> cxxflags;
  std::vector<std::string> fflags;
  std::vector<std::string> prefix_map;
  PackageCcFlags package;
  bool present = false;  // false: conf-less mode, only `cc` (from $JIG_CC) is set
};

// Reads <exe>/../etc/jig.json, else falls back to $JIG_CC. nullopt if neither names a compiler.
auto LoadDriverConf() -> std::optional<DriverConf>;
// `root`: the prefix "@/" in fflags stands for
auto ParseDriverConf(std::string_view text, std::string_view root = "") -> DriverConf;

// "libfoo.so" or "libfoo.so.1.2"
auto IsSharedLibName(std::string_view basename) -> bool;

// User argv -> real compiler argv: conf flags first, build-system rpaths filtered (store and
// build-tree entries pass, host dirs dropped), RUNPATH/interp policy appended when linking.
auto BuildDriverArgs(const DriverConf& conf, Language lang, std::span<const std::string> raw_args)
    -> std::vector<std::string>;

}  // namespace jig
