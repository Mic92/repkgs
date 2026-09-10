# CPU facts, the only place they live. `glibc.<cpu>` / `musl.<cpu>` / `forSystem` add the libc-
# dependent fields (triple, dynamic linker name). `flags` end up in every cc invocation via jig.conf.
# `names`: what other ecosystems call the cpu (kernel ARCH=, GOARCH, rust triple prefix, meson
# cpu_family, qemu-user binary, gyp/V8 dest-cpu) where it differs from ours.
let
  cpus = {
    x86_64 = {
      names = {
        kernel = "x86";
        go = "amd64";
        gyp = "x64";
      };
      march = [ "-march=x86-64-v3" ];
      hardening = [ "-fcf-protection=full" ];
      interp.glibc = "ld-linux-x86-64.so.2";
    };
    aarch64 = {
      names = {
        kernel = "arm64";
        go = "arm64";
        gyp = "arm64";
      };
      march = [ "-march=armv8.2-a+lse" ];
      hardening = [ "-mbranch-protection=standard" ];
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
      hardening = [ ];
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
      hardening = [ ];
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
      hardening = [ ];
      interp.glibc = "ld64.so.2";

    };
  };
  mk =
    cpu: libc:
    let
      c = cpus.${cpu};
    in
    (removeAttrs c [ "names" ])
    // {
      inherit cpu libc;
      os = "linux";
      names = builtins.mapAttrs (n: _: c.names.${n} or cpu) {
        kernel = null;
        go = null;
        rust = null;
        meson = null;
        qemu = null;
        gyp = null;
      };
      name = "${cpu}-linux";
      triple = "${cpu}-unknown-linux-${
        {
          glibc = "gnu";
          musl = "musl";
        }
        .${libc}
      }";
      interp = if libc == "musl" then "ld-musl-${cpu}.so.1" else c.interp.glibc;
      flags = c.march ++ c.hardening;
    };
  # Windows via mingw-w64 (ucrt): PE has no interp/RUNPATH, DLLs beside the .exe are already
  # relocatable, so finish/launchers have nothing to do. -fcf-protection is ELF-only (CET notes).
  mingw =
    cpu:
    let
      c = cpus.${cpu};
    in
    {
      inherit cpu;
      inherit (c) march;
      libc = "mingw";
      os = "windows";
      inherit (mk cpu "glibc") names;
      name = "${cpu}-windows";
      triple = "${cpu}-w64-mingw32";
      interp = "";
      hardening = [ ];
      flags = c.march;
    };
in
{
  forSystem = system: libc: mk (builtins.head (builtins.split "-" system)) libc;
  glibc = builtins.mapAttrs (cpu: _: mk cpu "glibc") cpus;
  musl = builtins.mapAttrs (cpu: _: mk cpu "musl") cpus;
  mingw = {
    x86_64 = mingw "x86_64";
    aarch64 = mingw "aarch64";
  };
}
