# clang's libraries (libclang for bindgen, libclang-cpp) against llvm<v>, as nixpkgs'
# clang-unwrapped is. The compiler in use stays `cc`. clang<v>/package.nix is `import this "<v>"`
v:
{
  variant,
  pkgs,
  buildPkgs,
  platform,
  on,
}:
let
  llvm = pkgs.${"llvm" + v};
  buildLlvm = buildPkgs.${"llvm" + v};
  buildClang = buildPkgs.${"clang" + v};
in
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
    }
    // on platform.cross { CLANG_TABLEGEN = "${buildClang}/bin/clang-tblgen"; };
    buildDependencies.append = on platform.cross [ buildClang ];
    # not installed upstream, a cross clang needs the build machine's
    phases.after.set."cmake.install" = [
      {
        name = "clang-tblgen";
        run = "cp bin/clang-tblgen $\"($c.out)/bin/\"";
      }
    ];
    bin.set = [ ];
  }
