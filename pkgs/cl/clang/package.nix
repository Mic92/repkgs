# clang's libraries (libclang for bindgen, libclang-cpp) against llvm<N>, as nixpkgs'
# clang-unwrapped is. The compiler in use stays `cc`
{
  variant,
  pkgs,
  buildPkgs,
  llvm ? pkgs.llvm,
  buildLlvm ? buildPkgs.llvm,
}:
import ../../ll/llvm/subproject.nix
  {
    inherit
      variant
      pkgs
      buildPkgs
      llvm
      buildLlvm
      ;
  }
  "clang"
  {
    cmake.defs.merge = {
      CLANG_LINK_CLANG_DYLIB = true;
      CLANG_INCLUDE_TESTS = false;
      CLANG_INCLUDE_DOCS = false;
      CLANG_BUILD_TOOLS = false;
      CLANG_BUILD_EXAMPLES = false;
      CLANG_ENABLE_ARCMT = false;
      CLANG_ENABLE_STATIC_ANALYZER = false;
      CLANG_TOOLING_BUILD_AST_INTROSPECTION = false;
      LIBCLANG_BUILD_STATIC = false;
    };
    bin.set = [ ];
  }
