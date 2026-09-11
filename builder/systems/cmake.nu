use ../core.nu *
use ../probe-cache.nu

# cmake configure / build / ctest / install with Ninja.
# -D values: bools as ON/OFF, everything else as written
def render [v: oneof<bool, int, string>]: nothing -> string {
  match $v { true => "ON", false => "OFF", _ => ($v | into string) }
}

export def setup []: nothing -> nothing { }

# out-of-tree
export def workdir []: nothing -> string { (ctx).build }

# cmake -G Ninja with prefix/libdir/prefix-path/shared/testing defaults, cross system + emulator, then `cmake.defs`
export def configure []: nothing -> nothing {
  let c = (ctx); let o = (options cmake)
  let defs = ({
    CMAKE_INSTALL_PREFIX: $c.out
    CMAKE_BUILD_TYPE: (if ($c.spec.profile? | default "release") == "debug" { "Debug" } else { "Release" })
    CMAKE_INSTALL_LIBDIR: "lib"
    CMAKE_PREFIX_PATH: ($c.deps | get root | str join ";")
    # what /usr is elsewhere, for find_path/find_library (the compiler knows, cmake does not)
    CMAKE_SYSTEM_PREFIX_PATH: $c.platform.sysroot
    BUILD_SHARED_LIBS: true
    BUILD_TESTING: $c.testsRun
  } | merge (if $c.platform.cross { {
    CMAKE_SYSTEM_NAME: ({linux: "Linux", windows: "Windows", macos: "Darwin"} | get $c.platform.os)
    CMAKE_SYSTEM_PROCESSOR: $c.platform.cpu
  } } else { {} }) | merge (if ($c.platform.emulator | is-empty) { {} } else { {CMAKE_CROSSCOMPILING_EMULATOR: ($c.platform.emulator | str join ";")} }) | merge $o.defs)
  let srcdir = (project-dir cmake)
  # results of check_*/try_compile (the project's INTERNAL cache entries) carried across builds
  let key = (probe-cache key cmake (glob $"($srcdir)/**/{CMakeLists.txt,*.cmake}"))
  let init = $"($c.build)/probe-init.cmake"
  let had = (probe-cache restore $key $init)
  note cmake-probes (if $had { "restored" } else { "cold" })
  x cmake -S $srcdir -B . -G $o.generator ...(if $had { [-C $init] } else { [] }) ...($defs | items {|k, v| $"-D($k)=(render $v)" }) ...$o.flags
  if not $had {
    open --raw CMakeCache.txt | lines | parse -r '^(?<k>[A-Za-z0-9_]+):INTERNAL=(?<v>.*)$'
      | where { not ($in.k | str starts-with "CMAKE_") and not ($in.k | str ends-with "-ADVANCED") and ($in.v !~ '/') }
      | each {|e| $"set\(($e.k) \"($e.v)\" CACHE INTERNAL \"\"\)" } | str join "\n" | save -f $init
    probe-cache store $key $init
  }
}

# cmake --build
export def build []: nothing -> nothing { x cmake --build . $"-j((ctx).njobs)" }
# ctest, tests.parallel as -j, cmake.skipTests joined into one -E regex
export def test []: nothing -> nothing {
  let skip = (options cmake).skipTests
  let exclude = (if ($skip | is-empty) { [] } else { [-E ($skip | str join "|")] })
  x ctest --output-on-failure -j (test-jobs) ...$exclude
}
# cmake --install
export def install []: nothing -> nothing { x cmake --install . }
