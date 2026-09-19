use ../core.nu *
use ../build-cache.nu

const SDK_LIBS = path self ./sdk-libs.cmake

# cmake configure / build / ctest / install with Ninja
export const OPTIONS = {
  defs: {default: {}, doc: "-D cache entries. true/false render ON/OFF, packages their store path"}
  generator: {default: Ninja, doc: "cmake -G"}
  flags: {default: [], doc: "extra arguments for cmake at configure time"}
  skipTests: {default: [], doc: "ctest -E regexes"}
}

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
    CMAKE_BUILD_TYPE: "Release"
    CMAKE_INSTALL_LIBDIR: "lib"
    CMAKE_INSTALL_SBINDIR: "bin"
    CMAKE_PREFIX_PATH: ($c.deps | get root | str join ";")
    CMAKE_SYSTEM_PREFIX_PATH: $c.platform.sysroot
    BUILD_SHARED_LIBS: true
    BUILD_TESTING: $c.testsRun
  } | merge (if $c.platform.cross { {
    CMAKE_SYSTEM_NAME: $c.platform.osNames.cmake
    CMAKE_SYSTEM_PROCESSOR: $c.platform.cpu
  } } else { {} }) | merge (if $c.platform.os == "macos" {
    # Darwin.cmake finds usr/ and the frameworks from this. find_library results inside it become -l/-framework
    {CMAKE_OSX_SYSROOT: $c.platform.sysroot, CMAKE_PROJECT_TOP_LEVEL_INCLUDES: $SDK_LIBS}
  } else { {} }) | merge (if ($c.platform.emulator | is-empty) { {} } else { {CMAKE_CROSSCOMPILING_EMULATOR: ($c.platform.emulator | str join ";")} }) | merge $o.defs)
  let srcdir = (project-dir cmake)
  # build cache: CMakeCache.txt's INTERNAL entries (check_*, try_compile, pkg_check_modules) become
  # the next same-key build's initial cache. The key pins sources, flags, dependencies and prefix,
  # so they are carried whole, paths included
  let key = (build-cache key cmake (files $"($srcdir)/**/{CMakeLists.txt,*.cmake}"))
  let init = $"($c.build)/probe-init.cmake"
  let had = (build-cache restore $key $init)
  note cmake-probes (if $had { "restored" } else { "cold" })
  x cmake -S $srcdir -B . -G $o.generator ...(if $had { [-C $init] } else { [] }) ...($defs | items {|k, v| $"-D($k)=(render $v)" }) ...$o.flags
  if not $had {
    internal-entries (open --raw CMakeCache.txt)
      # not cmake's own: those follow from our -D flags and toolchain file
      | where { not ($in.k | str starts-with "CMAKE_") and ($in.k !~ '-(ADVANCED|STRINGS|MODIFIED)$') }
      | each {|e| $"set\([[($e.k)]] [==[($e.v)]==] CACHE INTERNAL \"\"\)" } | str join "\n" | save -f $init
    build-cache store $key $init
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

# the INTERNAL entries of a CMakeCache.txt, parsed as cmState::ParseCacheEntry does
# (`"key":` when the key has a colon, trailing blanks dropped, 'quoted ' values unwrapped)
export def internal-entries [text: string]: nothing -> table<k: string, v: string> {
  $text | lines
    | each {|l| $l | parse -r '^(?:"(?<q>[^"]*)"|(?<k>[^=:]*)):(?<t>[^=]*)=(?<v>.*[^\r\t ]|[\r\t ]*)[\r\t ]*$' | get -o 0 }
    | compact
    | where t == INTERNAL
    | each {|e| {k: ($e.k | default $e.q), v: (if $e.v =~ "^'.*'$" { $e.v | str substring 1..<-1 } else { $e.v })} }
}
