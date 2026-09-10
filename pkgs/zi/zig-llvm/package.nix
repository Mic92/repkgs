# LLVM with the clang and lld libraries, of the major zig links against (one behind ours,
# tracked by update.nu)
{ variant, pkgs }:
variant pkgs.llvm {
  # upstream a558d656 (LLVM 22): RDF specialised std::less/equal_to, which libc++ 23's
  # transparent-comparator machinery rejects
  patches.set = [ ./rdf-std-specializations.patch ];
  cmake.defs.merge = {
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
  phases.set = [
    "cmake.configure"
    "cmake.build"
    "cmake.install"
    {
      # python scripts clang installs regardless of CLANG_BUILD_TOOLS. zig needs the libraries
      name = "no-scripts";
      run = "glob $\"($c.out)/bin/{git-clang-format,hmaptool,scan-*,analyze-*,intercept-*}\" | each { rm $in }";
    }
  ];
}
