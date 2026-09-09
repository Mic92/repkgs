use ../core.nu *
use python.nu [tool-site-packages]
use ../sys-libs.nu

# A Python application installed from its uv.lock (fetch.pythonDeps):
#   $out/lib/<name>/site-packages   every locked dependency, then the project itself
#   $out/bin/<script>                its entry points, started by our python with that dir first on sys.path
# Wheels are unpacked with `installer`; sdists are built here with our toolchain and no build
# isolation, so their PEP 517 backends come from buildDependencies (uv does not lock them).
# ELFs inside binary wheels were linked elsewhere: the build system defaults `prebuilt = true`
# (nix/build-systems.nix) so finish implants our dynamic linker and a RUNPATH into them.
def options []: nothing -> record<deps: any, check: list<string>> { options-for pyapp {deps: null, check: []} }

def site-packages []: nothing -> string { let c = (ctx); $"($c.out)/lib/($c.spec.name)/site-packages" }

# PYTHONPATH: the application's site-packages (filling up during build) and the build backends
export def --env setup []: nothing -> nothing {
  let c = (ctx)
  mkdir (site-packages)
  load-env {
    PYTHONPATH: ([(site-packages)] ++ (tool-site-packages) | str join ":")
    PYTHONDONTWRITEBYTECODE: "1", PYTHONNOUSERSITE: "1", PIP_NO_INDEX: "1"
  }
  load-env (sys-libs env-for python $c.deps)
  cd (project-dir pyapp)
}

# dependencies (wheels as fetched, sdists compiled), then the project, then relink foreign ELFs
export def build []: nothing -> nothing {
  let c = (ctx)
  let deps = (options).deps
  let plan = (open $"($deps)/plan.json")
  let built = $"($c.build)/wheels"
  mkdir $built

  for sdist in ($plan | where kind == sdist) { build-sdist $"($deps)/dist/($sdist.file)" $sdist.name $built }
  let wheels = ($plan | where kind == wheel | each { $"($deps)/dist/($in.file)" }) ++ (glob $"($built)/*.whl")
  for wheel in $wheels { install-wheel $wheel }

  x python3 -m build --wheel --no-isolation --skip-dependency-check --outdir $"($c.build)/project" .
  install-wheel (glob $"($c.build)/project/*.whl" | first) --scripts
}

# `pyapp.check`: modules that must import with the final layout
export def test []: nothing -> nothing {
  for module in (options).check {
    with-env {PYTHONPATH: (site-packages)} { x python3 -c $"import ($module)" }
  }
}

# entry points: `installer` wrote them with a `#!python3` placeholder; point them at our
# interpreter and put the application's site-packages first, relative to the script itself
export def install []: nothing -> nothing {
  let c = (ctx)
  let python = ($c.deps | where name =~ '^cpython' | first | get root)
  let prelude = $"import os, sys; sys.path.insert\(0, os.path.join\(os.path.dirname\(os.path.realpath\(__file__)), '../lib/($c.spec.name)/site-packages'))"
  for script in (glob $"($c.out)/bin/*" --no-dir --no-symlink) {
    let lines = (open --raw $script | lines)
    if ($lines | first) !~ '^#!.*python' { continue }
    [$"#!($python)/bin/python3" $prelude] ++ ($lines | skip 1) | str join "\n" | save -f $script
    chmod +x $script
  }
}

# one sdist -> a wheel in `outdir`, built in its own scratch dir
def build-sdist [tarball: string, name: string, outdir: string]: nothing -> nothing {
  note sdist $name
  let dir = $"((ctx).build)/sdist/($name)"
  mkdir $dir
  x bsdtar -xf $tarball -C $dir --strip-components 1
  cd $dir
  x python3 -m build --wheel --no-isolation --skip-dependency-check --outdir $outdir .
}

# unpack a wheel into the application's site-packages. installer only knows prefix layouts
# (lib/python3.x/site-packages, bin), so stage and move; dependency scripts are dropped,
# the project's own land in $out/bin
def install-wheel [wheel: string, --scripts]: nothing -> nothing {
  let c = (ctx)
  let stage = $"($c.build)/stage"
  rm -rf $stage
  ^python3 -m installer --prefix $stage --no-compile-bytecode $wheel
  for entry in (glob $"($stage)/lib/python3*/site-packages/*") { mv $entry (site-packages) }
  if $scripts and ($"($stage)/bin" | path exists) {
    mkdir $"($c.out)/bin"
    for f in (glob $"($stage)/bin/*") { mv $f $"($c.out)/bin/" }
  }
}

