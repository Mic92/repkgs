# one llvm-project subtree (clang, lld) built standalone against an already built llvm<N>:
# same tarball and pin as that base, its libLLVM linked, its tblgen used
{
  variant,
  pkgs,
  buildPkgs,
  llvm,
  buildLlvm,
}:
root: tree:
variant llvm [
  {
    patches.set = [ ];
    cmake.root.set = root;
    cmake.defs.set = {
      LLVM_DIR = "${llvm}/lib/cmake/llvm";
      LLVM_TOOLS_BINARY_DIR = "${buildLlvm}/bin";
      LLVM_TABLEGEN_EXE = "${buildLlvm}/bin/llvm-tblgen";
      LLVM_LINK_LLVM_DYLIB = true;
      BUILD_SHARED_LIBS = false;
      LLVM_INCLUDE_TESTS = false;
      LLVM_PARALLEL_LINK_JOBS = 4;
    };
    # LLVMExports.cmake names ZLIB::ZLIB and zstd in libLLVM's link interface
    dependencies.set = [
      llvm
      pkgs.zlib
      pkgs.zstd
    ];
    buildDependencies.set = [
      buildPkgs.cpython
      buildLlvm
    ];
    phases.after.set = { };
    phases.remove.set = [ "cmake.test" ];
  }
  tree
]
