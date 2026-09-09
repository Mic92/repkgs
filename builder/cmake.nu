use core.nu *

# cmake configure / build / ctest / install with Ninja.
def knobs []: nothing -> record<defs: record, sourceDir: string, generator: string> { knobs-for cmake {defs: {}, sourceDir: ".", generator: "Ninja"} }

# -D values: bools as ON/OFF, everything else as written
def render [v: oneof<bool, int, string>]: nothing -> string {
  match $v { true => "ON", false => "OFF", _ => ($v | into string) }
}

# out-of-tree: work in the build directory
export def --env setup []: nothing -> nothing { cd (ctx).build }

# cmake -G Ninja with prefix/libdir/prefix-path/shared/testing defaults, cross system + emulator, then `cmake.defs`
export def configure []: nothing -> nothing {
  let c = (ctx); let k = (knobs)
  cd $c.build
  let defs = ({
    CMAKE_INSTALL_PREFIX: $c.out
    CMAKE_BUILD_TYPE: (if ($c.spec.profile? | default "release") == "debug" { "Debug" } else { "Release" })
    CMAKE_INSTALL_LIBDIR: "lib"
    CMAKE_PREFIX_PATH: ($c.deps | get root | str join ";")
    BUILD_SHARED_LIBS: true
    BUILD_TESTING: $c.testsRun
  } | merge (if $c.platform.cross { {
    CMAKE_SYSTEM_NAME: "Linux"
    CMAKE_SYSTEM_PROCESSOR: $c.platform.cpu
  } } else { {} }) | merge (if ($c.platform.emulator | is-empty) { {} } else { {CMAKE_CROSSCOMPILING_EMULATOR: ($c.platform.emulator | str join ";")} }) | merge $k.defs)
  let srcdir = $"($c.src)/($k.sourceDir)"
  # results of check_*/try_compile (the project's INTERNAL cache entries) carried across builds
  let key = (probe-cache-key cmake (glob $"($srcdir)/**/{CMakeLists.txt,*.cmake}"))
  let init = $"($c.build)/probe-init.cmake"
  let had = (probe-cache-get $key $init)
  note cmake-probes (if $had { "restored" } else { "cold" })
  x cmake -S $srcdir -B . -G $k.generator ...(if $had { [-C $init] } else { [] }) ...($defs | items {|k, v| $"-D($k)=(render $v)" })
  if not $had {
    open --raw CMakeCache.txt | lines | parse -r '^(?<k>[A-Za-z0-9_]+):INTERNAL=(?<v>.*)$'
      | where { not ($in.k | str starts-with "CMAKE_") and not ($in.k | str ends-with "-ADVANCED") and ($in.v !~ '/') }
      | each {|e| $"set\(($e.k) \"($e.v)\" CACHE INTERNAL \"\"\)" } | str join "\n" | save -f $init
    probe-cache-put $key $init
  }
}

# cmake --build
export def build []: nothing -> nothing { cd (ctx).build; x cmake --build . -j ((ctx).njobs) }
# ctest, honouring tests.parallel and tests.skip (regex-joined -E)
export def test []: nothing -> nothing {
  let c = (ctx); cd $c.build
  if not $c.testsRun { return }
  let exclude = (if (test-skips | is-empty) { [] } else { [-E (test-skips | str join "|")] })
  x ctest --output-on-failure -j (test-jobs) ...$exclude
}
# cmake --install
export def install []: nothing -> nothing { cd (ctx).build; x cmake --install . }
