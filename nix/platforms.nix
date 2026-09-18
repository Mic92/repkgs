# CPU facts, the only place they live. `glibc.<cpu>` / `musl.<cpu>` / `forSystem` add the libc-
# dependent fields (clangTarget/gnuTriple/rustTriple, dynamic linker name) and `binfmt` (elf | macho | coff), which is what
# decides linker flavour, PIC, crt objects, interp/RUNPATH and whether launchers apply.
# `march` ends up in every cc invocation via jig.conf, on linux with `cf`, the cpu's control-flow
# hardening. `hardening` is the cpu's verdict on builder/hardening.nu names it cannot take.
# `names`: what other ecosystems call the cpu (kernel ARCH=, GOARCH, rust triple prefix, meson
# cpu_family, qemu-user binary, gyp/V8 dest-cpu, apple's clang arch) where it differs from ours,
# and `osNames` the same for the os (cmake CMAKE_SYSTEM_NAME, meson system and kernel, GOOS,
# gyp/node --dest-os).
let
  # file name pieces per binary format (and import library convention). Versioned shared
  # library names order differently per format: `shlib` / `linklib` in builder/core.nu
  extFor = binfmt: libc: {
    exe = if binfmt == "coff" then ".exe" else "";
    shared =
      {
        elf = ".so";
        macho = ".dylib";
        coff = ".dll";
      }
      .${binfmt};
    static = if libc == "msvc" then ".lib" else ".a";
    # what -l<name> finds for a shared library where that is not the library itself
    import =
      {
        msvc = ".lib";
        mingw = ".dll.a";
      }
      .${libc} or null;
  };
  oses = {
    linux.osNames = {
      cmake = "Linux";
      meson = "linux";
      mesonKernel = "linux";
      go = "linux";
      gyp = "linux";
      uname = "Linux";
    };
    windows.osNames = {
      cmake = "Windows";
      meson = "windows";
      mesonKernel = "nt";
      go = "windows";
      gyp = "win";
      uname = "Windows_NT";
    };
    macos.osNames = {
      cmake = "Darwin";
      meson = "darwin";
      mesonKernel = "xnu";
      go = "darwin";
      gyp = "mac";
      uname = "Darwin";
    };
  };
  cpus = {
    x86_64 = {
      names = {
        kernel = "x86";
        go = "amd64";
        gyp = "x64";
        openssl = "linux-x86_64";
      };
      march = [ "-march=x86-64-v3" ];
      cf = [ "-fcf-protection=full" ];
      interp.glibc = "ld-linux-x86-64.so.2";
    };
    aarch64 = {
      names = {
        kernel = "arm64";
        go = "arm64";
        gyp = "arm64";
        clang = "arm64";
        openssl = "linux-aarch64";
      };
      march = [ "-march=armv8.2-a+lse" ];
      cf = [ "-mbranch-protection=standard" ];
      interp.glibc = "ld-linux-aarch64.so.1";
    };
    riscv64 = {
      names = {
        kernel = "riscv";
        rust = "riscv64gc";
      };
      # -mno-relax: lld 21 leaves R_RISCV_IRELATIVE addends unadjusted after relaxation, so ld.so
      # jumps into the middle of memcpy instead of the ifunc resolver (every dynamic program SIGSEGVs)
      march = [
        "-march=rv64gc"
        "-mabi=lp64d"
        "-mno-relax"
      ];
      # clang 23.1 SIGSEGVs in prologue/epilogue insertion on frames over 4 KiB with it
      hardening.zerocallusedregs = false;
      interp.glibc = "ld-linux-riscv64-lp64d.so.1";
    };
    # Loongson 3A5000+ (LA464): the LA64 v1.0 baseline every shipped core has
    loongarch64 = {
      names = {
        kernel = "loongarch";
        go = "loong64";
        gyp = "loong64";
      };
      march = [
        "-march=loongarch64"
        "-mabi=lp64d"
      ];
      # clang has it for x86, arm and riscv only
      hardening.zerocallusedregs = false;
      interp.glibc = "ld-linux-loongarch-lp64d.so.1";
    };
    # POWER9 and later, little endian, ELFv2, IEEE long double (what current distros ship)
    powerpc64le = {
      names = {
        kernel = "powerpc";
        go = "ppc64le";
        meson = "ppc64";
        gyp = "ppc64";
        qemu = "ppc64le";
        openssl = "linux-ppc64le";
      };
      # clang defaults to the IBM long double unless built with PPC_LINUX_DEFAULT_IEEELONGDOUBLE,
      # and warns about -mabi= unless it finds a glibc >= 2.32 at /lib64/ld64.so.2
      march = [
        "-mcpu=power9"
        "-mabi=ieeelongdouble"
        "-Wno-unsupported-abi"
      ];
      hardening.zerocallusedregs = false;
      interp.glibc = "ld64.so.2";

    };
  };
  mk =
    cpu: libc:
    let
      c = cpus.${cpu};
    in
    (removeAttrs c [
      "names"
      "cf"
    ])
    // rec {
      inherit cpu libc;
      march = c.march ++ c.cf or [ ];
      hardening = c.hardening or { };
      inherit (oses.linux) osNames;
      os = "linux";
      abi = "gnu";
      posix = true;
      binfmt = "elf";
      ext = extFor binfmt libc;
      names = builtins.mapAttrs (n: _: c.names.${n} or cpu) {
        kernel = null;
        go = null;
        rust = null;
        meson = null;
        qemu = null;
        gyp = null;
        clang = null; # apple triples say arm64
        openssl = null;
      };
      name = "${cpu}-linux";
      # three spellings of one platform, named by consumer: clang -target, configure --host
      # (config.sub), rustc/cargo. They coincide on linux and diverge on macos (arm64-apple-macos14
      # vs aarch64-apple-darwin), so there is no plain `triple` to reach for
      clangTarget = "${cpu}-unknown-linux-${
        {
          glibc = "gnu";
          musl = "musl";
        }
        .${libc}
      }";
      gnuTriple = clangTarget;
      rustTriple = "${names.rust}-unknown-linux-${if libc == "musl" then "musl" else "gnu"}";
      opensslTarget = c.names.openssl or "linux64-${cpu}"; # its Configure's own table
      interp = if libc == "musl" then "ld-musl-${cpu}.so.1" else c.interp.glibc;
    };
  # The non-Linux targets. PE and Mach-O find libraries beside the binary / by install name, so
  # there is no interp and finish/launchers have nothing to do. macOS and msvc take libc, C++
  # library and SDK as given (pkgs/ap/apple-sdk, pkgs/wi/windows-sdk); windows gnu is mingw-w64
  # on UCRT with our libc++. `abi` tells the two windows apart, `posix` is what packages needing
  # fork/signals/ttys ask for. `minos` is the deployment target.
  given =
    cpu: o:
    let
      c = cpus.${cpu};
    in
    rec {
      inherit cpu;
      inherit (mk cpu "glibc") names;
      inherit (oses.${o.os}) osNames;
      name = "${cpu}-${o.os}";
      posix = o.os != "windows";
      interp = "";
      ext = extFor o.binfmt o.libc;
      march = o.march or c.march;
      hardening = { };
    }
    // o;
  msvc =
    cpu:
    given cpu rec {
      name = "${cpu}-windows-msvc";
      os = "windows";
      binfmt = "coff";
      libc = "msvc";
      abi = "msvc";
      clangTarget = "${cpu}-pc-windows-msvc";
      gnuTriple = clangTarget;
      rustTriple = clangTarget;
      opensslTarget = if cpu == "aarch64" then "VC-WIN64-CLANGASM-ARM" else "VC-WIN64A";
    };
  mingw =
    cpu:
    given cpu rec {
      name = "${cpu}-windows-gnu";
      os = "windows";
      binfmt = "coff";
      libc = "mingw";
      abi = "gnu";
      clangTarget = "${cpu}-w64-mingw32";
      gnuTriple = clangTarget;
      rustTriple = "${cpu}-pc-windows-gnullvm";
      opensslTarget = if cpu == "aarch64" then "mingwarm64" else "mingw64";
    };
  macos =
    cpu:
    given cpu rec {
      os = "macos";
      abi = "apple";
      binfmt = "macho";
      libc = "apple";
      minos = "14.0";
      clangTarget = "${cpus.${cpu}.names.clang or cpu}-apple-macos${minos}";
      gnuTriple = "${cpu}-apple-darwin";
      rustTriple = "${cpu}-apple-darwin";
      opensslTarget = "darwin64-${cpus.${cpu}.names.clang or cpu}";
      march = [ "-mcpu=apple-m1" ];
    };
in
rec {
  forSystem = system: libc: mk (builtins.head (builtins.split "-" system)) libc;
  # every target platform by its name. glibc linux for all cpus, the rest as listed
  byName = builtins.listToAttrs (
    map
      (p: {
        inherit (p) name;
        value = p;
      })
      (
        map (cpu: mk cpu "glibc") (builtins.attrNames cpus)
        ++ [
          (msvc "x86_64")
          (msvc "aarch64")
          (mingw "x86_64")
          (mingw "aarch64")
          (macos "aarch64")
        ]
      )
  );
}
