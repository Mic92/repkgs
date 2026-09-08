use core.nu *

# cmake configure / build / ctest / install with Ninja.
def knobs []: nothing -> record<defs: record, sourceDir: string, generator: string> { knobs-for cmake {defs: {}, sourceDir: ".", generator: "Ninja"} }

def render [v]: nothing -> string {  # nu-lint-ignore: add_type_hints_arguments
  match ($v | describe) { "bool" => (if $v { "ON" } else { "OFF" }), _ => ($v | into string) }
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
    CMAKE_SYSTEM_PROCESSOR: $c.platform.cmakeProcessor
  } } else { {} }) | merge (if ($c.platform.emulator | is-empty) { {} } else { {CMAKE_CROSSCOMPILING_EMULATOR: ($c.platform.emulator | str join ";")} }) | merge $k.defs)
  x cmake -S $"($c.src)/($k.sourceDir)" -B . -G $k.generator ...($defs | items {|k, v| $"-D($k)=(render $v)" })
}

# cmake --build
export def build []: nothing -> nothing { cd (ctx).build; x cmake --build . -j ((ctx).njobs) }
# ctest, honouring tests.parallel and tests.skip (regex-joined -E)
export def test []: nothing -> nothing {
  let c = (ctx); cd $c.build
  if not $c.testsRun { return }
  let skip = ($c.spec.tests?.skip? | default [])
  x ctest --output-on-failure -j (if ($c.spec.tests?.parallel? | default true) { $c.njobs } else { 1 }) ...(if ($skip | is-empty) { [] } else { ["-E" ($skip | str join "|")] })
}
# cmake --install
export def install []: nothing -> nothing { cd (ctx).build; x cmake --install . }
