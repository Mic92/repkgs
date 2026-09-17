# CPython itself, the interpreter package. The python *build system* module is what builds wheels.
{
  package,
  sources,
  pkgs,
  platform,
  buildPkgs,
  on,
  lib,
  pythonProject,
}:
let
  msvc = platform.abi == "msvc";
  self = package args // pythonProject package self;
  args = {
    name = "cpython314";
    # configure: "cross build not supported" for mingw
    platforms.libc = [
      "glibc"
      "musl"
      "apple"
      "msvc"
    ];
    uses = [ (if msvc then "vcxproj" else "autotools") ];
    autotools = lib.on (!msvc) {
      flags = [
        "--disable-test-modules"
        "--without-ensurepip"
        "--with-openssl=${pkgs.openssl}"
        "--with-system-libmpdec"
        "ac_cv_file__dev_ptmx=yes"
        "ac_cv_file__dev_ptc=no"
        # by name: AC_PATH_TOOL would record the toolchain's store path in _sysconfigdata
        "ac_cv_path_LLVM_PROFDATA=llvm-profdata"
        "ac_cv_path_ac_pt_LLVM_PROFDATA=llvm-profdata"
        "ac_cv_path_LLVM_AR=llvm-ar"
        "ac_cv_path_ac_pt_LLVM_AR=llvm-ar"
      ]
      # cross: configure needs a same-version build-machine python and cannot run test programs
      ++ (
        if platform.cross then
          [
            "--with-build-python=python3" # by name: _sysconfigdata records CONFIG_ARGS
            "ac_cv_buggy_getaddrinfo=no"
          ]
        else
          [ ]
      );
    };
    # no compiled-in PREFIX: an installed python is where its binary (/proc/self/exe, as macOS
    # asks the OS) or libpython is, a build tree one uses the source dir. sysconfig data and .pyc
    # paths relative, python-config from $0. LIBPL gets no copy of the build Makefile and
    # python-config.py (records of the build, nothing reads them)
    patches = [
      ./relocatable.patch
      ./upstream-darwin-cross-xopen.patch
    ];
    # pcbuild.proj is the solution's traversal project. _freeze_module is a build-machine tool
    # (cpython.frozen-modules stands in), the py launcher and shell extension are installer material
    vcxproj = lib.on msvc {
      projects = [ "PCbuild/pcbuild.proj" ];
      exclude = [
        "_freeze_module"
        "pylauncher"
        "pywlauncher"
        "pyshellext"
      ];
      # PCbuild compiles these libraries in from source directories it is pointed at
      properties = {
        bz2Dir = "${pkgs.bzip2.src}/";
        mpdecimalDir = "${pkgs.mpdecimal.src}/";
        lzmaDir = "${sources.fetch "xz"}/";
        sqlite3Dir = "${sources.fetch "sqlite"}/";
        zstdDir = "${pkgs.zstd.src}/";
        zlibNgDir = "${sources.fetch "zlib-ng"}/";
      };
      install.DynamicLibrary = "DLLs";
      install.Application = ".";
    };
    phases.before."vcxproj.configure" = lib.on msvc [
      "cpython.properties"
      "cpython.frozen-modules"
      "cpython.zlib-ng-headers"
    ];
    phases.after."vcxproj.install" = lib.on msvc [ "cpython.windows-layout" ];
    phases.after."autotools.install" = lib.on (!msvc) [ "cpython.build-details" ];
    tests.run = false; # hours
    dependencies = lib.on (!msvc) [
      pkgs.zlib
      pkgs.xz
      pkgs.bzip2
      pkgs.libffi
      pkgs.openssl
      pkgs.expat
      pkgs.sqlite
      pkgs.mpdecimal
    ];
    buildDependencies = on platform.cross [ buildPkgs.cpython ];
    bin = [ (if msvc then "python" else "python3") ];
    # bin/ is where finish.nu looks; the Windows layout has python.exe at the root
    links = lib.on msvc { "bin/python" = "python"; };
  };
in
self
