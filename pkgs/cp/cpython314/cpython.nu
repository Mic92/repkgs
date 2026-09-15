use core.nu *
use msbuild.nu

# PCbuild/python.props reads the version out of patchlevel.h with property functions. The same
# numbers from the package version, as MSBuild global properties
export def --env properties []: nothing -> nothing {
  let c = (ctx)
  let v = ($c.spec.version | parse -r '^(?<maj>\d+)\.(?<min>\d+)\.(?<mic>\d+)(?<lvl>a|b|rc)?(?<ser>\d+)?$' | first)
  let level = ({a: 10, b: 11, rc: 12} | get -o ($v.lvl | default "") | default 15)
  let serial = ($v.ser | default -e "0" | into int)
  let props = {
    Configuration: Release, Platform: x64, PlatformToolset: ClangCL
    MajorVersionNumber: $v.maj, MinorVersionNumber: $v.min, MicroVersionNumber: $v.mic
    ReleaseLevelName: $"($v.lvl)($v.ser)", _ReleaseLevel: "", ReleaseSerial: ($serial | into string), ReleaseLevelNumber: ($level | into string)
    PythonVersionHex: ((($v.maj | into int) * 16777216 + ($v.min | into int) * 65536 + ($v.mic | into int) * 256 + $level * 16 + $serial) | into string)
    Field3Value: (($serial + $level * 10 + ($v.mic | into int) * 1000) | into string)
    OverrideVersion: $c.spec.version
    PySourcePath: $"($c.src)/", Py_OutDir: $"($c.build)/out", Py_IntDir: $"($c.build)/obj"
    IncludeSSL: "false", IncludeTkinter: "false", IncludeTests: "false", IncludeCTypes: "false", IncludeUwp: "false"
  }
  $env.PKGS_CTX = ($c | upsert spec.vcxproj.properties ($props | merge $c.spec.vcxproj.properties))
}

# _freeze_module.vcxproj builds a host _freeze_module.exe and runs it over its <None> and
# <GetPath> items. Cross, the build python's Programs/_freeze_module.py writes the same headers
# (marshal of the same version), which is what PCbuild does for ARM64 too
export def frozen-modules []: nothing -> nothing {
  let c = (ctx)
  let r = (msbuild evaluate $"($c.src)/PCbuild/_freeze_module.vcxproj" $c.spec.vcxproj.properties)
  let mods = ($r.items | where type in [None GetPath] | where { $in.meta.ModName? != null })
  note freeze $"($mods | length) modules with the build python"
  for m in $mods {
    let out = (msbuild win-path $m.meta.OutFile $"($c.src)/PCbuild")
    mkdir ($out | path dirname)
    x python3 $"($c.src)/Programs/_freeze_module.py" $m.meta.ModName $m.path $out
  }
}

# zlib-ng.vcxproj's _EnsureZlibH targets: zlib.h and zlib-ng.h from the .h.in, no symbol prefix
export def zlib-ng-headers []: nothing -> nothing {
  let c = (ctx)
  let p = $c.spec.vcxproj.properties
  let r = (msbuild evaluate $"($c.src)/PCbuild/zlib-ng.vcxproj" $p)
  let d = (msbuild win-path $r.props.GeneratedZlibNgDir $"($c.src)/PCbuild")
  mkdir $d
  for h in [zlib zlib-ng] {
    open --raw $"($p.zlibNgDir)/($h).h.in" | str replace -a "@ZLIB_SYMBOL_PREFIX@" "" | save -f $"($d)/($h).h"
  }
}

# what PC/layout (the installer's tree) makes of the build directory: python.exe, python3*.dll
# at the root, extension modules in DLLs\, the stdlib in Lib\, headers in include\, import libraries in libs\
export def windows-layout []: nothing -> nothing {
  let c = (ctx)
  mkdir $"($c.out)/libs"
  for f in (files $"($c.out)/lib/*.lib") { mv $f $"($c.out)/libs/" }
  rm -rf $"($c.out)/lib"
  x cp -r $"($c.src)/Lib" $"($c.out)/Lib"
  rm -rf $"($c.out)/Lib/test" ...(glob $"($c.out)/Lib/**/__pycache__")
  mkdir $"($c.out)/include"
  x cp -r ...(glob $"($c.src)/Include/*") $"($c.src)/PC/pyconfig.h" $"($c.out)/include/"
}

# build-details.json (PEP 739) records the paths of the python that ran the generator, under
# cross the build machine's: ours by layout, relative as --relative-paths would write them
export def build-details []: nothing -> nothing {
  let c = (ctx)
  let f = (files $"($c.out)/lib/python3.*/build-details.json" | first)
  let py = ($f | path dirname | path basename)
  let details = (open $f | reject libpython.static | merge deep {
    base_prefix: "../.."
    base_interpreter: $"./bin/($py)"
    libpython: {dynamic: $"./lib/lib($py).so", dynamic_stableabi: "./lib/libpython3.so"}
    c_api: {headers: $"./include/($py)", pkgconfig_path: "./lib/pkgconfig"}
  })
  $details | save -f $f
}
