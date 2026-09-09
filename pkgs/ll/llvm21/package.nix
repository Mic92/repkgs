# LLVM 21 with the clang and lld libraries: what zig 0.16 links against (it tracks LLVM one
# major behind ours). Same shape as pkgs/ll/llvm otherwise.
{
  package,
  pkgs,
  buildPkgs,
}:
package {
  name = "llvm21";
  uses = [ "cmake" ];
  cmake.sourceDir = "llvm";
  # upstream a558d656 (LLVM 22): RDF specialised std::less/equal_to, which libc++ 23's
  # transparent-comparator machinery rejects
  patches = [ ./rdf-std-specializations.patch ];
  cmake.defs = (import ../llvm/defs.nix) // {
    # zig's cmake refuses an LLVM without every default target
    LLVM_TARGETS_TO_BUILD = "all";
    LLVM_ENABLE_PROJECTS = "clang;lld";
    CLANG_LINK_CLANG_DYLIB = true;
    CLANG_INCLUDE_TESTS = false;
    CLANG_INCLUDE_DOCS = false;
    CLANG_BUILD_TOOLS = false;
    CLANG_ENABLE_ARCMT = false;
    CLANG_ENABLE_STATIC_ANALYZER = false;
    LIBCLANG_BUILD_STATIC = false;
    LLD_BUILD_TOOLS = false;
  };
  dependencies = [
    pkgs.zlib
    pkgs.zstd
  ];
  buildDependencies = [ buildPkgs.cpython ];
  tests.run = false; # hours, as llvm
  bin = [ "llvm-config" ];
}
