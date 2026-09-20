# The Fortran runtime for the target (libflang_rt.runtime.a, intrinsic .mod files), compiled
# by the build machine's flang, plus jig as bin/{gfortran,flang,fortran} with a jig.json that
# runs that flang against cc's sysroot and this runtime
{
  variant,
  pkgs,
  buildPkgs,
  platform,
  lib,
  toolchain,
}:
let
  flang = "${buildPkgs.flang}/bin/flang";
  # flang rejects the clang-only per-cpu flags (-mabi, -mbranch-protection, ...)
  target = [
    "--target=${platform.clangTarget}"
  ]
  ++ builtins.filter (f: builtins.match "-m(arch|cpu)=.*" f != null) platform.march
  ++ [ "--sysroot=${toolchain.sysroot}" ];
in
import ../../ll/llvm/subproject.nix
  {
    inherit variant pkgs buildPkgs;
    inherit (pkgs) llvm;
    buildLlvm = buildPkgs.llvm;
  }
  "runtimes"
  {
    name.set = "flang-rt";
    cmake.defs.merge = {
      LLVM_ENABLE_RUNTIMES = "flang-rt";
      LLVM_DEFAULT_TARGET_TRIPLE = platform.clangTarget;
      CMAKE_Fortran_COMPILER = flang;
      CMAKE_Fortran_COMPILER_WORKS = true;
      CMAKE_Fortran_FLAGS = lib.join " " target;
      FLANG_RT_INCLUDE_TESTS = false;
    }
    # IEEE long double would need __fixkfti and quadmath support compiler-rt lacks. flang has no
    # REAL(16) on ppc64le, so IBM long double loses nothing
    // lib.on (platform.cpu == "powerpc64le") {
      CMAKE_CXX_FLAGS = "-mabi=ibmlongdouble";
      HAVE_LDBL_MANT_DIG_113 = false;
      FOUND_LIBMF128 = false;
    };
    # a static runtime, nothing of llvm is linked (LLVM_DIR still finds its cmake files)
    dependencies.set = [ ];
    platforms.set.os = [ "linux" ];
    phases.after.set."cmake.install" = [
      {
        name = "gfortran";
        run = ''
          # "@/" is jig's own prefix (driver.cc), so the conf survives the move to the store
          let rt = (files --dirs $"($c.out)/lib/clang/*/lib/*" | first | str replace $c.out "@")
          let finclude = (files --dirs $"($c.out)/lib/clang/*/finclude/flang/*" | first | str replace $c.out "@")
          mkdir $"($c.out)/bin" $"($c.out)/etc"
          let fflags = [-B${toolchain}/bin ${lib.join " " target} $"-resource-dir=($c.platform.sysroot)/lib/clang" -rtlib=compiler-rt -fintrinsic-modules-path $finclude $"-L($rt)"]
          open "${toolchain}/etc/jig.json" | reject flags cxxflags prefix-map | merge {fc: "${flang}", fflags: $fflags} | save $"($c.out)/etc/jig.json"
          cp "${toolchain}/etc/roots" $"($c.out)/etc/"
          cp "${toolchain}/bin/jig" $"($c.out)/bin/"
          for n in [gfortran flang fortran] { ln -s jig $"($c.out)/bin/($n)" }
        '';
      }
      {
        name = "hello.f90";
        run = ''
          "program h\n use iso_fortran_env\n print *, compiler_version()\nend program\n" | save hello.f90
          x $"($c.out)/bin/gfortran" hello.f90 -o hello
          if not $c.platform.cross { x ./hello }
        '';
      }
    ];
    bin.set = [ "gfortran" ];
  }
