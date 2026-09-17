use ../core.nu *
use python.nu [tool-site-packages maturin-interpreter]
use cargo.nu
use ../sys-libs.nu
use ../implant.nu

# A Python project installed from its uv.lock (fetch.pythonDeps):
#   $out/lib/<name>/site-packages   every locked dependency, then (mode project) the project itself
#   $out/bin/<script>                entry points, run by our python with that directory first on sys.path
# Wheels are unpacked with `installer`. sdists are built here, without build isolation, so their
# PEP 517 backends are the build tools. Binary wheels contain ELFs linked elsewhere, hence
# `prebuilt = true` in nix/build-systems.nix: finish implants our dynamic linker and RUNPATH.
export const OPTIONS = {
  check: {default: [], doc: "modules that must import from the installed layout"}
  mode: {default: project, doc: "project | env (dependencies and bin/python3 only) | dev (env whose python also imports $REPKGS_PROJECT). nix/python.nix sets it"}
  overrides: {default: {}, doc: "per locked package name: {patches, env, run (nu, in its unpacked source), configSettings} for its sdist build"}
}

def site-packages []: nothing -> string { let c = (ctx); $"($c.out)/lib/($c.spec.name)/site-packages" }

# PYTHONPATH: the application's site-packages (filling up during build) and the build backends
export def --env setup []: nothing -> nothing {
  let c = (ctx)
  mkdir (site-packages)
  load-env {
    PYTHONPATH: ([(site-packages)] ++ (tool-site-packages) | str join ":")
    PYTHONDONTWRITEBYTECODE: "1", PYTHONNOUSERSITE: "1", PIP_NO_INDEX: "1"
  }
  sys-libs check (project-dir pyapp) $c.spec.sys
  load-env (sys-libs env-for python $c.deps)
}

export def workdir []: nothing -> string { project-dir pyapp }

# dependencies (wheels as fetched, sdists compiled), then the project, then relink foreign ELFs
export def build []: nothing -> nothing {
  let c = (ctx)
  let deps = (options pyapp).deps
  let plan = (open $"($deps)/plan.json")
  let built = $"($c.build)/wheels"
  mkdir $built

  let o = (options pyapp)
  let mode = $o.mode
  for sdist in ($plan | where kind == sdist) { build-sdist $"($deps)/dist/($sdist.file)" $sdist.name $built ($o.overrides | get -o $sdist.name) }
  # workspace members and path sources are directories of ours, git sources come fetched
  for tree in ($plan | where kind == tree) {
    let dir = (if $tree.file == "" { $"($c.src)/($tree.path)" } else { $"($deps)/($tree.file)" })
    build-tree $dir $tree.name $built ($o.overrides | get -o $tree.name)
  }
  let wheels = ($plan | where kind == wheel | each { $"($deps)/dist/($in.file)" }) ++ (files $"($built)/*.whl")
  for wheel in $wheels { install-wheel $wheel --scripts=($mode != project) }

  if $mode == project {
    x python3 -m build --wheel --no-isolation --skip-dependency-check --outdir $"($c.build)/project" .
    install-wheel (files $"($c.build)/project/*.whl" | first) --scripts
  } else {
    env-python $mode
  }
  # the test phase imports them before finish would get to it
  implant $c
}

# bin/python3 as a sh wrapper that sets PYTHONPATH. A pyvenv.cfg would pin an absolute `home`
def env-python [mode: string]: nothing -> nothing {
  let c = (ctx)
  let python = ($c.deps | where name =~ '^cpython' | first | get root)
  let dev = (if $mode == dev { '${REPKGS_PROJECT:+$REPKGS_PROJECT:$REPKGS_PROJECT/src:}' } else { "" })
  mkdir $"($c.out)/bin"
  let text = $"#!/bin/sh
here=$\(cd "$\(dirname "$0")" && pwd -P)
export PYTHONPATH="($dev)$here/../lib/($c.spec.name)/site-packages${PYTHONPATH:+:$PYTHONPATH}"
exec ($python)/bin/python3 "$@"
"
  $text | save -f $"($c.out)/bin/python3"
  chmod +x $"($c.out)/bin/python3"
  ^ln -s python3 $"($c.out)/bin/python"
}

# `pyapp.check`: modules that must import with the final layout
export def test []: nothing -> nothing {
  for module in (options pyapp).check {
    with-env {PYTHONPATH: (site-packages)} { x python3 -c $"import ($module)" }
  }
}

# entry points: `installer` wrote them with a `#!python3` placeholder; point them at our
# interpreter and put the site-packages first, relative to the script itself
export def install []: nothing -> nothing {
  let c = (ctx)
  let python = ($c.deps | where name =~ '^cpython' | first | get root)
  let dev = (if (options pyapp).mode == dev { "; p = os.environ.get('REPKGS_PROJECT'); sys.path[0:0] = [p, os.path.join(p, 'src')] if p else []" } else { "" })
  let prelude = $"import os, sys; sys.path.insert\(0, os.path.join\(os.path.dirname\(os.path.realpath\(__file__)), '../lib/($c.spec.name)/site-packages'))($dev)"
  for script in (files --no-symlink $"($c.out)/bin/*") {
    let lines = (open --raw $script | lines)
    if ($lines | first) !~ '^#!.*python' { continue }
    [$"#!($python)/bin/python3" $prelude] ++ ($lines | skip 1) | str join "\n" | save -f $script
    chmod +x $script
  }
}

# one sdist -> a wheel in `outdir`, built in its own scratch dir
def build-sdist [tarball: string, name: string, outdir: string, ov: any]: nothing -> nothing {
  note sdist $name
  let dir = $"((ctx).build)/sdist/($name)"
  mkdir $dir
  x bsdtar -xf $tarball -C $dir --strip-components 1
  build-wheel $dir $name $outdir $ov
}

def build-tree [src: string, name: string, outdir: string, ov: any]: nothing -> nothing {
  note tree $name
  let dir = $"((ctx).build)/sdist/($name)"
  rm -rf $dir
  mkdir ($dir | path dirname)
  ^cp -r --no-preserve=mode $src $dir
  build-wheel $dir $name $outdir $ov
}

# `ov`: this package's pyapp.overrides entry (patches, env, run, configSettings)
def build-wheel [dir: string, name: string, outdir: string, ov: any]: nothing -> nothing {
  cd $dir
  let ov = ($ov | default {})
  for p in ($ov.patches? | default []) { x patch -p1 -i $p }
  if ($ov.run? | default "") != "" { x nu -c $ov.run }
  # maturin / setuptools-rust sdists: crates were vendored by fetch/pypi-vendor.nu, and cargo is
  # set up as for a cargo package (offline, our linkers, the target's std when cross compiling)
  let vendor = $"((options pyapp).deps)/vendor/($name)"
  if ($vendor | path exists) {
    cargo configure $vendor $"((ctx).build)/cargo-home/($name)"
    $env.MATURIN_PEP517_ARGS = $"--interpreter (maturin-interpreter) --auditwheel skip"
  }
  let settings = ((sys-libs tables).python | get -o $name | get -o configSettings | default {} | merge ($ov.configSettings? | default {}) | items {|k, v| $"-C($k)=($v)" })
  with-env ($ov.env? | default {}) {
    x python3 -m build --wheel --no-isolation --skip-dependency-check --outdir $outdir ...$settings .
  }
}

# unpack a wheel into the application's site-packages. installer only knows prefix layouts
# (lib/python3.x/site-packages, bin), so stage and move; dependency scripts are dropped,
# the project's own land in $out/bin
def install-wheel [wheel: string, --scripts]: nothing -> nothing {
  let c = (ctx)
  let stage = $"($c.build)/stage"
  rm -rf $stage
  ^python3 -m installer --prefix $stage --no-compile-bytecode $wheel
  # namespace packages (sphinxcontrib/, google/) come in pieces from several wheels: merge trees
  for sp in (files --dirs $"($stage)/lib/python3*/site-packages") { ^cp -rlf $"($sp)/." (site-packages); rm -rf $sp }
  if $scripts and ($"($stage)/bin" | path exists) {
    mkdir $"($c.out)/bin"
    for f in (files $"($stage)/bin/*") { mv $f $"($c.out)/bin/" }
  }
}

