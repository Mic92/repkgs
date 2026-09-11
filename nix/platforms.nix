# CPU facts, the only place they live. `glibc.<cpu>` / `musl.<cpu>` / `forSystem` add the libc-
# dependent fields (triple, dynamic linker name) and `binfmt` (elf | macho | coff), which is what
# decides linker flavour, PIC, crt objects, interp/RUNPATH and whether launchers apply.
# `march` ends up in every cc invocation via jig.conf. `hardening` is the cpu's verdict on
# nix/hardening.nix names: what it adds (cfprotection, branchprotection) or cannot take.
# `names`: what other ecosystems call the cpu (kernel ARCH=, GOARCH, rust triple prefix, meson
# cpu_family, qemu-user binary, gyp/V8 dest-cpu, apple's clang arch) where it differs from ours,
# and `osNames` the same for the os (cmake CMAKE_SYSTEM_NAME, meson system and kernel, GOOS).
let
  oses = {
    linux.osNames = {
      cmake = "Linux";
      meson = "linux";
      mesonKernel = "linux";
      go = "linux";
    };
    windows.osNames = {
      cmake = "Windows";
      meson = "windows";
      mesonKernel = "nt";
      go = "windows";
    };
    macos.osNames = {
      cmake = "Darwin";
      meson = "darwin";
      mesonKernel = "xnu";
      go = "darwin";
    };
  };
  cpus = {
    x86_64 = {
      names = {
        kernel = "x86";
        go = "amd64";
        gyp = "x64";
      };
      march = [ "-march=x86-64-v3" ];
      hardening.cfprotection = true;
      interp.glibc = "ld-linux-x86-64.so.2";
    };
    aarch64 = {
      names = {
        kernel = "arm64";
        go = "arm64";
        gyp = "arm64";
        clang = "arm64";
      };
      march = [ "-march=armv8.2-a+lse" ];
      hardening.branchprotection = true;
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
      };
      march = [ "-mcpu=power9" ];
      interp.glibc = "ld64.so.2";

    };
  };
  mk =
    cpu: libc:
    let
      c = cpus.${cpu};
    in
    (removeAttrs c [ "names" ])
    // rec {
      inherit cpu libc;
      inherit (oses.linux) osNames;
      os = "linux";
      binfmt = "elf";
      names = builtins.mapAttrs (n: _: c.names.${n} or cpu) {
        kernel = null;
        go = null;
        rust = null;
        meson = null;
        qemu = null;
        gyp = null;
        clang = null; # apple triples say arm64
      };
      name = "${cpu}-linux";
      triple = "${cpu}-unknown-linux-${
        {
          glibc = "gnu";
          musl = "musl";
        }
        .${libc}
      }";
      rustTriple = "${names.rust}-unknown-linux-${if libc == "musl" then "musl" else "gnu"}";
      interp = if libc == "musl" then "ld-musl-${cpu}.so.1" else c.interp.glibc;
    };
  # The non-Linux targets take libc, C++ library and SDK as given (pkgs/wi/windows-sdk,
  # pkgs/ap/apple-sdk). PE and Mach-O find libraries beside the binary / by install name, so there
  # is no interp and finish/launchers have nothing to do. Windows is the MSVC ABI every other
  # Windows binary has. macOS links with ld64.lld, `minos` is the deployment target.
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
      interp = "";
      march = o.march or c.march;
      hardening = { };
    }
    // o;
  msvc =
    cpu:
    given cpu {
      os = "windows";
      binfmt = "coff";
      libc = "msvc";
      triple = "${cpu}-pc-windows-msvc";
      rustTriple = "${cpu}-pc-windows-msvc";
    };
  macos =
    cpu:
    given cpu rec {
      os = "macos";
      binfmt = "macho";
      libc = "apple";
      minos = "14.0";
      triple = "${cpus.${cpu}.names.clang or cpu}-apple-macos${minos}";
      configTriple = "${cpu}-apple-darwin"; # the GNU spelling, for configure --host
      rustTriple = "${cpu}-apple-darwin";
      march = [ "-mcpu=apple-m1" ];
    };
in
{
  forSystem = system: libc: mk (builtins.head (builtins.split "-" system)) libc;
  glibc = builtins.mapAttrs (cpu: _: mk cpu "glibc") cpus;
  musl = builtins.mapAttrs (cpu: _: mk cpu "musl") cpus;
  msvc = {
    x86_64 = msvc "x86_64";
    aarch64 = msvc "aarch64";
  };
  macos.aarch64 = macos "aarch64";
}
