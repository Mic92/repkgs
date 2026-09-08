// The C/C++ compiler entry point (argv[0] = cc, c++, gcc, g++, clang, clang++).
//
// Cached: `cc -c x.c` (the object), `cc x.c -o x` with no object inputs (configure and cmake
// probes), `cc *.o *.a -o x` (a link: keyed on the InputId of every object argument, lld's
// --dependency-file adds crt files, -l libraries and linker scripts to the manifest), and compile
// *failures* whose inputs are all known. Never cached: -E/-S/-M runs, several sources at once,
// sources mixed with objects, @response files, a failure caused by something absent (missing
// header, any link error) that a later build might provide.
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
  std::string source;                 // the one translation unit, or the output name of a link (log label)
  std::vector<std::string> inputs;    // object/archive/shared-object arguments of a link
  std::filesystem::path output;       // object for -c, else the executable / shared object
  bool compile_only = false;
  bool link_one = false;  // one source straight to an executable, no object inputs
  bool link = false;      // objects only
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
