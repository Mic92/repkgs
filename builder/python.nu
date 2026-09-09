use core.nu *

# PEP 517 wheel build + install (setuptools/flit/hatch via `build`, maturin directly), import check, optional pytest.
def knobs []: nothing -> record<backend: string, module: any, pytest: bool> { knobs-for python {backend: "setuptools", module: null, pytest: false} }

def site-packages [roots: list<string>]: nothing -> list<string> { $roots | each {|r| glob $"($r)/lib/python3*/site-packages" } | flatten }

# PYTHONPATH = dependencies' site-packages, cwd = `python.root`
export def --env setup []: nothing -> nothing {
  let c = (ctx)
  load-env {PYTHONDONTWRITEBYTECODE: "1", PIP_NO_INDEX: "1"}
  # python deps and build backends are packages with a site-packages dir. The source tree comes
  # last so a backend can build itself (flit_core, setuptools) before any of the stack exists
  let root = (project-dir python)
  let own = ([$root $"($root)/src"] | where { $in | path exists })
  $env.PYTHONPATH = ((site-packages (($c.deps | get root) ++ ($env.PATH | each { path dirname }))) ++ $own | str join ":")
  cd $root
}

# build one wheel into the build dir: `python -m build` for PEP 517 backends, `maturin build` for maturin
export def build []: nothing -> nothing {
  let c = (ctx); let k = (knobs)
  cd (project-dir python)
  let dist = $"($c.build)/dist"
  if $k.backend == "maturin" {
    # maturin's PEP 517 backend only shells out to `maturin`. Call it directly. cargo setup came from `uses`.
    # auditwheel=skip: the wheel is installed into this closure, not shipped to PyPI. Bundling our libunwind is wrong
    x maturin build --release --offline -j ($c.njobs | into string) --interpreter python3 --auditwheel skip -o $dist
  } else if $k.backend == "flit_core" {
    # flit_core builds wheels stand-alone: no `build`/`pyproject_hooks` needed (bootstraps the stack)
    x python3 -m flit_core.wheel --outdir $dist .
  } else {
    x python3 -m build --wheel --no-isolation --skip-dependency-check --outdir $dist .
  }
}

# install the wheel into $out with `installer`, or unzip it when installer is not packaged yet
export def install []: nothing -> nothing {
  let c = (ctx)
  let whl = (glob $"($c.build)/dist/*.whl" | first)
  if (^python3 -c "import installer" | complete).exit_code == 0 {
    x python3 -m installer --prefix $c.out $whl
  } else {
    let ver = (^python3 -c "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')" | str trim)
    let sp = $"($c.out)/lib/python($ver)/site-packages"
    mkdir $sp
    x bsdtar -xf $whl -C $sp
  }
  # entry-point scripts run under another package's interpreter and get re-exec'd by path (meson
  # --internal), so no env var will do: each script puts our and our python dependencies'
  # site-packages on sys.path itself, relative to its own location
  let rels = (site-packages ([$c.out] ++ ($c.deps | get root))
    | each {|p| if ($p | str starts-with $c.out) { $"..($p | str substring ($c.out | str length)..)" } else { $"../../($p | path relative-to $env.NIX_STORE)" } })
  let boot = ('import os, sys; sys.path[0:0] = [os.path.join(os.path.dirname(os.path.realpath(__file__)), p) for p in RELS]' | str replace RELS ($rels | to json -r))
  for f in (glob $"($c.out)/bin/*" --no-dir --no-symlink) {
    let text = (open --raw $f | into binary)
    if not ($text | bytes starts-with ("#!" | into binary)) { continue }
    let lines = ($text | decode utf-8 | lines)
    if ($lines | first) !~ "python" { continue }
    [($lines | first) $boot] ++ ($lines | skip 1) | str join "\n" | save -f $f
  }
}

# runs after install: imports from $out, not from the source tree
export def test []: nothing -> nothing {
  let c = (ctx); let k = (knobs)
  let mod = ($k.module | default ($c.spec.name | str replace -a "-" "_"))
  cd $c.build
  $env.PYTHONPATH = (site-packages [$c.out] | append $env.PYTHONPATH | str join ":")
  x python3 -c $"import ($mod)"
  if $k.pytest { x python3 -m pytest -q $"($c.src)/tests" }
}
