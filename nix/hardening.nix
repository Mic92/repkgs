# Hardening flags by their nixpkgs names. `default` is on for every package unless the package
# (`cc.hardening.<name> = false`) or the platform (nix/platforms.nix `hardening`) says otherwise.
# builder/env.nu applies the result per package, bootstrap/ gives the toolchain recipes the
# platform's own additions.
rec {
  flags = {
    fortify = [ "-D_FORTIFY_SOURCE=3" ];
    stackprotector = [ "-fstack-protector-strong" ];
    stackclashprotection = [ "-fstack-clash-protection" ];
    trivialautovarinit = [ "-ftrivial-auto-var-init=zero" ];
    format = [
      "-Wformat"
      "-Wformat-security"
      "-Werror=format-security"
    ];
    strictoverflow = [ "-fwrapv" ];
    strictflexarrays = [ "-fstrict-flex-arrays=1" ];
    zerocallusedregs = [ "-fzero-call-used-regs=used-gpr" ];
    noplt = [ "-fno-plt" ];
    cfprotection = [ "-fcf-protection=full" ];
    branchprotection = [ "-mbranch-protection=standard" ];
    libcxxhardening = [ "-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_FAST" ];
    relro = [ "-Wl,-z,relro" ];
    bindnow = [ "-Wl,-z,now" ];
    relr = [ "-Wl,-z,pack-relative-relocs" ];
  };
  # which go on the c++ line only, which on the link line. The rest are compile flags
  cxx = [ "libcxxhardening" ];
  link = [
    "relro"
    "bindnow"
    "relr"
  ];
  # off unless the cpu turns them on, and then part of the toolchain's fixed flags
  cpuOnly = [
    "cfprotection"
    "branchprotection"
  ];
  default = builtins.mapAttrs (_: _: true) (removeAttrs flags cpuOnly);
  # name -> bool for one platform: the defaults with the cpu's verdicts merged over
  forPlatform = platform: default // (platform.hardening or { });
  enabledFlags =
    enabled: names: builtins.concatMap (n: if enabled.${n} or false then flags.${n} else [ ]) names;
}
