use core.nu *

# meson setup / compile / test / install.
def knobs []: nothing -> record<options: record, sourceDir: string> { knobs-for meson {options: {}, sourceDir: "."} }

# option values are bools, ints or strings
def render [v]: nothing -> string {  # nu-lint-ignore: add_type_hints_arguments
  if ($v | describe) == "bool" { if $v { "true" } else { "false" } } else { $v | into string }
}

# out-of-tree: work in the build directory
export def --env setup []: nothing -> nothing { cd (ctx).build }

# cross: meson wants a file, not flags. Generated from the platform record
def cross-file [c: record]: nothing -> string {
  let p = $c.platform
  let cpu = $p.cpu
  let fam = $p.names.meson
  let f = $"($c.build)/cross.ini"
  [ "[binaries]" "c = 'cc'" "cpp = 'c++'" "ar = 'llvm-ar'" "strip = 'llvm-strip'" "pkg-config = 'pkg-config'"
    ...(if ($p.emulator | is-empty) { [] } else {
      let quoted = ($p.emulator | each {|e| $"'($e)'" } | str join ", ")
      [$"exe_wrapper = [($quoted)]"] })
    "[host_machine]" "system = 'linux'" $"cpu_family = '($fam)'" $"cpu = '($cpu)'" "endian = 'little'"
    "[properties]" "needs_exe_wrapper = true" ] | str join "\n" | save -f $f
  $f
}

# meson setup with prefix/libdir/buildtype defaults, a generated cross file when cross, then `meson.options`
export def configure []: nothing -> nothing {
  let c = (ctx); let k = (knobs)
  cd $c.build
  let opts = ({
    prefix: $c.out
    libdir: "lib"
    buildtype: (if ($c.spec.profile? | default "release") == "debug" { "debug" } else { "plain" })  # plain: our CFLAGS rule
    default_library: "shared"
    wrap_mode: "nodownload"
    auto_features: "disabled"   # nothing found by accident; packages enable what they declare
  } | merge $k.options)
  let cross = (if $c.platform.cross { ["--cross-file" (cross-file $c)] } else { [] })
  x meson setup . $"($c.src)/($k.sourceDir)" ...$cross ...($opts | items {|k, v| $"-D($k)=(render $v)" })
}

# ninja
export def build []: nothing -> nothing { cd (ctx).build; x ninja -j ((ctx).njobs) }
# meson test, honouring tests.skip
export def test []: nothing -> nothing {
  let c = (ctx); cd $c.build
  if not $c.testsRun { return }
  let skip = ($c.spec.tests?.skip? | default [])
  # meson has no exclude flag. Skipped tests are listed by name and filtered from `meson test --list`
  let names = (if ($skip | is-empty) { [] } else { ^meson test --list | lines | where {|t| not ($skip | any {|s| $t =~ $s }) } })
  x meson test --no-rebuild --print-errorlogs --num-processes (if ($c.spec.tests?.parallel? | default true) { $c.njobs } else { 1 }) ...$names
}
# meson install
export def install []: nothing -> nothing { cd (ctx).build; x meson install --no-rebuild }
