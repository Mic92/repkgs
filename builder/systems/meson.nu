use ../core.nu *

# meson setup / compile / test / install.
export def setup []: nothing -> nothing { }

# out-of-tree
export def workdir []: nothing -> string { (ctx).build }

# machine file values are meson literals: 'str', [list], true, 1
def literal [v: oneof<string, list<any>, bool, int>]: nothing -> string {
  match ($v | describe | str replace -r '<.*' '') {
    "string" => $"'($v)'"
    "list" => $"[($v | each {|e| literal $e } | str join ', ')]"
    _ => ($v | into string)
  }
}

def machine-file [path: path, sections: record]: nothing -> string {
  $sections | items {|name, kv| ([$"[($name)]"] ++ ($kv | items {|k, v| $"($k) = (literal $v)" })) | str join "\n" } | str join "\n\n" | save -f $path
  $path
}

# cross: meson takes machines from files, not the environment. The host (target) machine is our
# cc/c++, the build machine cc-build with a pkg-config that finds nothing, so build-time tools
# never link target libraries. sizeof/alignment go in as properties so cc.sizeof() & co. need
# no exe wrapper; the emulator still serves cc.run()/tests.
def cross-files [c: record]: nothing -> list<string> {
  let p = $c.platform
  let host = (machine-file $"($c.build)/cross.ini" {
    binaries: ({c: "cc", cpp: "c++", ar: "llvm-ar", nm: "llvm-nm", strip: "llvm-strip", objcopy: "llvm-objcopy", pkg-config: "pkg-config"}
      | merge (if ($p.emulator | is-empty) { {} } else { {exe_wrapper: $p.emulator} }))
    properties: {needs_exe_wrapper: true, sizeof_void_p: 8, sizeof_long: 8, sizeof_size_t: 8, alignment_void_p: 8, alignment_double: 8
      sys_root: ($env.PKGS_SYSROOT? | default ""), pkg_config_libdir: ($env.PKG_CONFIG_PATH? | default "")}
    host_machine: {system: ({linux: linux, windows: windows, macos: darwin} | get $p.os), kernel: ({linux: linux, windows: nt, macos: xnu} | get $p.os), cpu_family: $p.names.meson, cpu: $p.cpu, endian: "little"}
  })
  # an empty, existing dir: pkg-config with PKG_CONFIG_LIBDIR pointing there finds nothing
  mkdir $"($c.build)/no-pc"
  $"#!(tool sh)\nPKG_CONFIG_PATH= PKG_CONFIG_LIBDIR=${0%/*}/no-pc exec pkg-config \"$@\"\n" | save -f $"($c.build)/pkg-config-build"
  chmod +x $"($c.build)/pkg-config-build"
  let native = (machine-file $"($c.build)/native.ini" {
    binaries: {c: "cc-build", cpp: "c++-build", ar: "llvm-ar", strip: "llvm-strip", pkg-config: $"($c.build)/pkg-config-build"}
  })
  [--cross-file $host --native-file $native]
}

# meson setup with prefix/libdir/buildtype defaults, a generated cross file when cross, then `meson.defs`
export def configure []: nothing -> nothing {
  let c = (ctx); let o = (options meson)
  let opts = ({
    prefix: $c.out
    libdir: "lib"
    buildtype: (if ($c.spec.profile? | default "release") == "debug" { "debug" } else { "plain" })  # plain: cc brings -O2 -g itself
    default_library: "shared"
    wrap_mode: "nodownload"
    auto_features: "disabled"   # nothing found by accident; packages enable what they declare
  } | merge $o.defs)
  let cross = (if $c.platform.cross { cross-files $c } else { [] })
  x meson setup . (project-dir meson) ...$cross ...($opts | items {|k, v| $"-D($k)=($v | into string)" }) ...$o.flags
}

# ninja
export def build []: nothing -> nothing { x ninja $"-j((ctx).njobs)" }
# meson test. meson has no exclude flag: every test no meson.skipTests regex matches is named
export def test []: nothing -> nothing {
  let skip = (options meson).skipTests
  let names = (if ($skip | is-empty) { [] } else { ^meson test --list | lines | where {|t| not ($skip | any {|s| $t =~ $s }) } })
  x meson test --no-rebuild --print-errorlogs --num-processes (test-jobs) ...$names
}
# meson install
export def install []: nothing -> nothing { x meson install --no-rebuild }
