# Hardening flags by their nixpkgs names. On for every package unless the package
# (`cc.hardening.<name> = false`, `cc.hardening = false`) or the platform says otherwise: ELF-only
# ones are off for PE and Mach-O, nix/platforms.nix `hardening` carries the cpu's verdicts. The
# cpu's own additions (cf-protection, BTI) are not here: they are fixed toolchain flags
# (platforms.nix `march`). env.nu turns `enabled-flags` into $PKGS_CC.

const FLAGS = {
  fortify: ["-D_FORTIFY_SOURCE=3"]
  stackprotector: ["-fstack-protector-strong"]
  stackclashprotection: ["-fstack-clash-protection"]
  trivialautovarinit: ["-ftrivial-auto-var-init=zero"]
  format: ["-Wformat" "-Wformat-security" "-Werror=format-security"]
  strictoverflow: ["-fwrapv"]
  strictflexarrays: ["-fstrict-flex-arrays=1"]
  zerocallusedregs: ["-fzero-call-used-regs=used-gpr"]
  noplt: ["-fno-plt"]
  libcxxhardening: ["-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_FAST"]
  relro: ["-Wl,-z,relro"]
  bindnow: ["-Wl,-z,now"]
  relr: ["-Wl,-z,pack-relative-relocs"]
  noexecstack: ["-Wl,-z,noexecstack"]
  asneeded: ["-Wl,--as-needed"]
}
# which go on the c++ line only, which on the link line. The rest are compile flags
const CXX = [libcxxhardening]
const LINK = [relro bindnow relr noexecstack asneeded]
# ELF linker and loader features: lld-link and ld64 have no -z, PE and Mach-O no PLT or RELRO
const ELF_ONLY = [relro bindnow relr noexecstack asneeded noplt stackclashprotection]

# {cflags cxxflags ldflags} for one package: `platform` from ctx, `cc` the spec's cc record
export def enabled-flags [platform: record, cc: record]: nothing -> record<cflags: list<string>, cxxflags: list<string>, ldflags: list<string>> {
  let base = ($FLAGS | columns | each {|n| {$n: ($platform.binfmt == "elf" or $n not-in $ELF_ONLY)} } | into record)
  let pkg = ($cc.hardening? | default {})
  let enabled = (if $pkg == false { {} } else {
    let unknown = ($pkg | columns | where { $in not-in ($FLAGS | columns) })
    if ($unknown | is-not-empty) { error make {msg: $"cc.hardening: unknown ($unknown | str join ', '), known: ($FLAGS | columns | str join ' ')"} }
    $base | merge ($platform.hardening? | default {}) | merge $pkg
  })
  let pick = {|names: list<string>| $names | where {|n| ($enabled | get -o $n) == true } | each {|n| $FLAGS | get $n } | flatten }
  {
    cflags: (do $pick ($FLAGS | columns | where { $in not-in ($CXX ++ $LINK) }))
    cxxflags: (do $pick $CXX)
    ldflags: (do $pick $LINK)
  }
}
