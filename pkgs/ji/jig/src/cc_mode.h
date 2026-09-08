// The C/C++ compiler entry point (argv[0] = cc, c++, gcc, g++, clang, clang++).
//
// Cached: `cc -c x.c` (the object), `cc x.c -o x` with no object/archive inputs, i.e. configure
// and cmake probes (the executable, where lld's --dependency-file adds crt files and libraries to
// the manifest), and compile *failures* whose inputs are all known. Never cached: real links, -E/-S/-M
// runs, several sources at once, a failure caused by something absent (missing header, any link
// error) that a later build might provide.
#ifndef PKGS_CC_CC_MODE_H_
#define PKGS_CC_CC_MODE_H_

#include <filesystem>
#include <span>
#include <string>
#include <vector>

namespace jig {

struct Invocation {
  std::vector<std::string> args;      // passed to the real compiler
  std::vector<std::string> key_args;  // what influences the output: all but -o, depfile options, the source
  std::string source;
  std::filesystem::path output;  // object for -c, executable for a one-source link
  bool compile_only = false;
  bool link_one = false;  // one source straight to an executable, no object inputs
  bool cacheable = true;
  // depfile requested by the build system (-MD/-MMD/-MF/-MT/-Wp,-MD,…): left out of the key,
  // cached as an extra artifact so a hit reproduces it
  bool wants_depfile = false;
  std::filesystem::path depfile;
};

auto ParseInvocation(std::span<const std::string> args) -> Invocation;

auto RunCcMode(std::string_view argv0, std::span<const std::string> user_args, const std::string& socket_path) -> int;

}  // namespace jig

#endif  // PKGS_CC_CC_MODE_H_
