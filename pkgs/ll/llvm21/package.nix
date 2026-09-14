# libLLVM of the major zig links against (update.nu tracks it). clang21 and lld21 build on it
{ variant, pkgs }:
variant pkgs.llvm {
  # upstream a558d656 (LLVM 22): RDF specialised std::less/equal_to, which libc++ 23's
  # transparent-comparator machinery rejects
  patches.set = [ ./upstream-rdf-std-specializations.patch ];
  # zig's cmake refuses an LLVM that lacks a default target
  cmake.defs.merge.LLVM_TARGETS_TO_BUILD = "all";
}
