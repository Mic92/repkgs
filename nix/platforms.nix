# CPU facts, the only place they live. `glibc.<cpu>` / `musl.<cpu>` / `forSystem` add the libc-
# dependent fields (triple, dynamic linker name). `flags` end up in every cc invocation via jig.conf.
# `names`: what other ecosystems call the cpu (kernel ARCH=, GOARCH, rust triple prefix, meson
# cpu_family, qemu-user binary) where it differs from ours.
let
  cpus = {
    x86_64 = {
      names = {
        kernel = "x86";
        go = "amd64";
      };
      march = [ "-march=x86-64-v3" ];
      hardening = [ "-fcf-protection=full" ];
      interp.glibc = "ld-linux-x86-64.so.2";
      glibcConfigure = [
        "libc_cv_have_x86_lahf_sahf=yes"
        "libc_cv_have_x86_movbe=yes"
      ];
    };
    aarch64 = {
      names = {
        kernel = "arm64";
        go = "arm64";
      };
      march = [ "-march=armv8.2-a+lse" ];
      hardening = [ "-mbranch-protection=standard" ];
      interp.glibc = "ld-linux-aarch64.so.1";
      glibcConfigure = [ ];
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
      glibcConfigure = [ ];
    };
    # Loongson 3A5000+ (LA464): the LA64 v1.0 baseline every shipped core has
    loongarch64 = {
      names = {
        kernel = "loongarch";
        go = "loong64";
      };
      march = [
        "-march=loongarch64"
        "-mabi=lp64d"
      ];
      hardening = [ ];
      interp.glibc = "ld-linux-loongarch-lp64d.so.1";
      glibcConfigure = [ ];
    };
    # POWER9 and later, little endian, ELFv2, IEEE long double (what current distros ship)
    powerpc64le = {
      names = {
        kernel = "powerpc";
        go = "ppc64le";
        meson = "ppc64";
        qemu = "ppc64le";
      };
      march = [ "-mcpu=power9" ];
      hardening = [ ];
      interp.glibc = "ld64.so.2";
      glibcConfigure = [ "--with-long-double-format=ieee" ];
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
      names = builtins.mapAttrs (n: _: c.names.${n} or cpu) {
        kernel = null;
        go = null;
        rust = null;
        meson = null;
        qemu = null;
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
in
{
  forSystem = system: libc: mk (builtins.head (builtins.split "-" system)) libc;
  glibc = builtins.mapAttrs (cpu: _: mk cpu "glibc") cpus;
  musl = builtins.mapAttrs (cpu: _: mk cpu "musl") cpus;
}
