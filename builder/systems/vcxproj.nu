use ../core.nu *
use ../msbuild.nu

# Visual Studio C/C++ projects without MSBuild: builder/msbuild.nu evaluates each .vcxproj to
# its sources, per-file compile settings and link inputs, this module writes one build.ninja for
# all of them (cc = jig + clang for the msvc target, lld-link, llvm-rc) and runs ninja.
# ProjectReference between listed projects orders the links and passes the import library along
export const OPTIONS = {
  projects: {default: [], doc: "the .vcxproj files to build, relative to the source root. A traversal .proj stands for what its Build target hands to <MSBuild>"}
  exclude: {default: [], doc: "project names (file stem) to leave out of what `projects` expands to"}
  properties: {default: {}, doc: "MSBuild global properties (Configuration, Platform and what the projects compute with property functions)"}
  install: {default: {}, doc: "ConfigurationType -> directory under the prefix, over {Application: bin, DynamicLibrary: bin, StaticLibrary: lib}"}
}

export def setup []: nothing -> nothing { }

export def workdir []: nothing -> string { (ctx).build }

# what Microsoft.Cpp.*.props defines before a project's own ItemDefinitionGroups
const TOOLSET = {Link: {AdditionalDependencies: "kernel32.lib;user32.lib;gdi32.lib;winspool.lib;comdlg32.lib;advapi32.lib;shell32.lib;ole32.lib;oleaut32.lib;uuid.lib;odbc32.lib;odbccp32.lib"}}

def list [s: any]: nothing -> list<string> { $s | default "" | split row ";" | each { str trim } | compact -e | uniq }

# ClCompile metadata -> clang (GNU driver) arguments. The cl.exe spellings projects put in
# AdditionalOptions are translated where clang has the option, dropped where it is MSVC codegen tuning
def cl-flags [meta: record, dir: string]: nothing -> list<string> {
  let m = {|k| $meta | get -o $k | default "" }
  let opt = ({Disabled: [-O0], MinSpace: [-Os], MaxSpeed: [-O2], Full: [-O3]} | get -o (do $m Optimization) | default [-O2])
  let rt = (match (do $m RuntimeLibrary) { "MultiThreaded" => [-fms-runtime-lib=static], "MultiThreadedDebug" => [-fms-runtime-lib=static_dbg], "MultiThreadedDebugDLL" => [-fms-runtime-lib=dll_dbg], _ => [-fms-runtime-lib=dll] })
  let eh = (match (do $m ExceptionHandling) { "Async" => [-fasync-exceptions], "false" => [-fno-exceptions], _ => [] })
  # /arch: as clang-cl maps it
  let arch = ({StreamingSIMDExtensions: [-msse], StreamingSIMDExtensions2: [-msse2], AdvancedVectorExtensions: [-mavx], AdvancedVectorExtensions2: [-mavx2]
      AdvancedVectorExtensions512: [-mavx512f -mavx512bw -mavx512cd -mavx512dq -mavx512vl]} | get -o (do $m EnableEnhancedInstructionSet) | default [])
  let std = {|k| let v = (do $m $k); if $v =~ '^std' { [$"-std=($v | str replace std '' | str replace cpp 'c++')"] } else { [] } }
  let extra = (list ((do $m AdditionalOptions) | str replace -a " " ";") | each {|o|
    match ($o | str replace -r '^-' '/') {
      "/utf-8" => [], "/MP" => [], "/bigobj" => [], "/FS" => []
      # LTO: hours of link time for the cache to miss on, cc.* options decide that here
      $x if $x =~ '^/flto|^/GL' => []
      $x if $x =~ '^/Zm\d+$' => []
      $x if $x =~ '^/d2' => []
      $x if $x =~ '^/arch:' => [$"-m($x | str replace '/arch:' '' | str lowercase)"]
      $x if $x =~ '^/std:' => [$"-std=($x | str replace '/std:' '' | str replace 'c++latest' 'c++2c')"]
      "/EHsc" => [], "/EHa" => [-fasync-exceptions]
      $x if $x =~ '^/w[de1-4]\d+$' => []
      _ => [$o]
    }
  } | flatten)
  ($opt ++ $rt ++ $eh ++ $arch ++ (do $std LanguageStandard) ++ (do $std LanguageStandard_C)
    ++ (defines (do $m PreprocessorDefinitions))
    ++ (list (do $m AdditionalIncludeDirectories) | each {|i| $"-I(msbuild win-path $i $dir)" })
    ++ (if (do $m CompileAs) == "CompileAsCpp" { [-x c++] } else if (do $m CompileAs) == "CompileAsC" { [-x c] } else { [] })
    ++ $extra)
}

# Link metadata -> lld-link arguments (passed through clang with -Wl so jig sees one link)
def link-flags [meta: record, kind: string, dir: string]: nothing -> list<string> {
  let m = {|k| $meta | get -o $k | default "" }
  let libs = (list (do $m AdditionalDependencies) | each {|l| if $l =~ '[\\/]' { msbuild win-path $l $dir } else { $"-l($l | str replace -r '\.lib$' '')" } })
  let simple = ([
      [SubSystem {|v| $"/subsystem:($v | str lowercase)" }]
      [StackReserveSize {|v| $"/stack:($v)" }]
      [ModuleDefinitionFile {|v| $"/def:(msbuild win-path $v $dir)" }]
      [BaseAddress {|v| $"/base:($v)" }]
      [EntryPointSymbol {|v| $"/entry:($v)" }]
      [NoEntryPoint {|v| if $v == "true" { "/noentry" } }]
    ] | each {|o| let v = (do $m $o.0); if $v != "" { do $o.1 $v } } | compact)
  let opts = ($simple ++ (list (do $m DelayLoadDLLs) | each {|d| $"/delayload:($d)" })
    ++ (list ((do $m AdditionalOptions) | str replace -a " " ";") | where { $in !~ '^[/-](LTCG|GENPROFILE|USEPROFILE|OPT:)' }))
  ($libs ++ (list (do $m AdditionalLibraryDirectories) | each {|d| $"-L(msbuild win-path $d $dir)" })
    ++ ($opts | each {|o| $"-Wl,($o)" }) ++ (if $kind == "DynamicLibrary" { [-shared] } else { [] }))
}

# MSBuild hands definitions to the tools through CommandLineToArgv, which eats the \" projects write
def defines [value: any]: nothing -> list<string> {
  list $value | each {|d| $"-D($d | str replace -a '\"' '"')" }
}

# .rc files include SDK headers: preprocessed by cc (its include paths and case-folding VFS),
# compiled by llvm-rc, which finds the files a statement names (ICON "icons\x.ico", separators
# turned) relative to the script or /I. rc.exe reads narrow strings in the ANSI code page, 1252
# on the machines these projects are written for
def rc-flags [meta: record, dir: string]: nothing -> list<string> {
  (defines $meta.PreprocessorDefinitions?) ++ (list $meta.AdditionalIncludeDirectories? | each {|i| $"-I(msbuild win-path $i $dir)" })
}

def nq [s: string]: nothing -> string { $s | str replace -a '$' '$$' | str replace -a ' ' '$ ' | str replace -a ':' '$:' }
def shq [s: string]: nothing -> string { if $s =~ '^[\w@%+=:,./-]+$' { $s } else { $"'($s | str replace -a "'" "'\\''")'" } }

# one evaluated project -> {name, kind, output, implib, refs, edges: [ninja text]}
def project [c: record, file: string, props: record]: nothing -> record {
  let path = $"($c.src)/($file)"
  let dir = ($path | path dirname)
  let r = (msbuild evaluate $path $props --itemdefs $TOOLSET)
  let kind = ($r.props.ConfigurationType? | default Application)
  let ext = ($r.props.TargetExt? | default -e ({Application: ".exe", DynamicLibrary: ".dll", StaticLibrary: ".lib"} | get $kind))
  let name = $"($r.props.TargetName? | default -e ($file | path parse | get stem))($ext)"
  let obj = $"($c.build)/obj/($file | path parse | get stem)"
  let live = {|t| $r.items | where type == $t | where { ($in.meta.ExcludedFromBuild? | default "") != "true" } }
  # object names: the source path with separators folded, unique across in-tree and external dirs
  let oname = {|p: string, ext: string| $"($obj)/($p | str trim -l -c '/' | str replace -a '/' '__').($ext)" }
  let objs = (do $live ClCompile | each {|it|
    let o = (do $oname $it.path obj)
    {out: $o, text: $"build (nq $o): (if $it.path =~ '\.(cc|cpp|cxx)$' { 'cxx' } else { 'cc' }) (nq $it.path)\n  flags = (cl-flags $it.meta $dir | each { shq $in } | str join ' ')\n"}
  })
  let res = (do $live ResourceCompile | each {|it|
    let o = (do $oname $it.path res)
    let rcdirs = ([($it.path | path dirname)] ++ (list $it.meta.AdditionalIncludeDirectories? | each {|i| msbuild win-path $i $dir }) | each {|d| $"/I (shq $d)" } | str join ' ')
    {out: $o, text: $"build (nq $o): rc (nq $it.path)\n  flags = (rc-flags $it.meta $dir | each { shq $in } | str join ' ')\n  rcflags = ($rcdirs)\n"}
  })
  # <CustomBuild>: a command line (ml64, a generator) with declared Outputs; .obj outputs are linked
  let custom = (do $live CustomBuild | each {|it|
    let outs = (list $it.meta.Outputs? | each { msbuild win-path $in $dir })
    let cmd = ($it.meta.Command | str replace -a '\' '/' | str replace -r '^ml64 ' 'llvm-ml64 ' | str replace -r '^ml ' 'llvm-ml ')
    {out: ($outs | where { $in =~ '\.obj$' }), text: $"build ($outs | each { nq $in } | str join ' '): custom (nq $it.path)\n  cmd = ($cmd)\n"}
  })
  let refs = ($r.items | where type == ProjectReference | get path | each { try { path relative-to $c.src } catch { $in } })
  # where the project puts it: sibling projects link it from there by -L$(OutDir)
  let outdir = (msbuild win-path ($r.props.OutDir? | default $"($c.build)/out/") $dir | str trim --right --char "/")
  let output = $"($outdir)/($name)"
  let implib = (if $kind == "Application" { null } else { $"($outdir)/($name | path parse | get stem).lib" })
  let parts = ($objs ++ $res ++ $custom)
  {name: $name, file: $file, kind: $kind, output: $output, implib: $implib, refs: $refs, inputs: ($parts | get out | flatten)
    link: (link-flags ($r.itemdefs.Link? | default {}) $kind $dir), edges: ($parts | get text)}
}

def ninja-file [c: record, projects: list<record>]: nothing -> string {
  let by_file = ($projects | each {|p| {k: $p.file, v: $p} } | transpose -r -d)
  const RULES = r#'rule cc
  command = cc -MD -MF $out.d $flags -c $in -o $out
  deps = gcc
  depfile = $out.d
  description = cc $out
rule cxx
  command = c++ -MD -MF $out.d $flags -c $in -o $out
  deps = gcc
  depfile = $out.d
  description = c++ $out
rule rc
  command = cc -E -xc -DRC_INVOKED $flags $in -o $out.i && sed -i -E '/^ *[0-9A-Za-z_]+ +(ICON|BITMAP|CURSOR|FONT|HTML|RT_MANIFEST|24|RCDATA|MESSAGETABLE) /s,[\],/,g' $out.i && llvm-rc /no-preprocess /C 1252 $rcflags /FO $out $out.i
  description = rc $out
rule link
  command = cc $in -o $main $flags
  description = link $out
rule lib
  command = llvm-lib /nologo /out:$out $in
  description = lib $out
rule custom
  command = $cmd
  description = $cmd
'#
  let links = ($projects | each {|p|
    # a referenced project that is built here contributes its import library and orders the link
    let deps = ($p.refs | each {|f| $by_file | get -o $f } | compact | where kind != Application)
    let implibs = ($deps | get implib | compact)
    if $p.kind == "StaticLibrary" {
      $"build (nq $p.implib): lib ($p.inputs | each { nq $in } | str join ' ')\n"
    } else {
      let also = (if $p.implib != null { $" | (nq $p.implib)" } else { "" })
      let iflag = (if $p.implib != null { [$"-Wl,/implib:($p.implib)"] } else { [] })
      $"build (nq $p.output)($also): link ($p.inputs | each { nq $in } | str join ' ') ($implibs | each { nq $in } | str join ' ')\n  main = (nq $p.output)\n  flags = (($p.link ++ $iflag) | each { shq $in } | str join ' ')\n"
    }
  })
  [$RULES] ++ ($projects | get edges | flatten) ++ $links | str join "\n"
}

export def projects []: nothing -> list<record> {
  let c = (ctx)
  let o = (options vcxproj)
  if ($o.projects | is-empty) { error make {msg: "vcxproj.projects is empty"} }
  $o.projects | each {|f|
    if $f !~ '\.proj$' { return [$f] }
    let dir = ($"($c.src)/($f)" | path dirname)
    msbuild sub-projects (msbuild evaluate $"($c.src)/($f)" $o.properties) Build $dir | each { path relative-to $c.src }
  } | flatten | uniq | where { ($in | path parse | get stem) not-in $o.exclude }
  | each {|f| project $c $f $o.properties }
}

export def configure []: nothing -> nothing {
  let c = (ctx)
  let ps = (projects)
  mkdir ...($ps | get output | path dirname | uniq)
  for p in $ps { note project $"($p.file): ($p.kind) ($p.name), ($p.inputs | length) objects" }
  ninja-file $c $ps | save -f $"($c.build)/build.ninja"
  $ps | select name kind output implib file | to json | save -f $"($c.build)/projects.json"
}

export def build []: nothing -> nothing {
  x ninja -C (ctx).build $"-j((ctx).njobs)"
}

export def install []: nothing -> nothing {
  let c = (ctx)
  let o = (options vcxproj)
  let dirs = ({Application: bin, DynamicLibrary: bin, StaticLibrary: lib} | merge $o.install)
  for p in (open $"($c.build)/projects.json") {
    let d = $"($c.out)/($dirs | get $p.kind)"
    mkdir $d
    if $p.kind != "StaticLibrary" { ^cp $p.output $d }
    if $p.implib != null and ($p.implib | path exists) { mkdir $"($c.out)/lib"; ^cp $p.implib $"($c.out)/lib/" }
  }
}
