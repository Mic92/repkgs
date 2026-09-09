use core.nu *

# A bun project: `bun install --offline` from fetch.bunDeps, optional `bun run <script>`, `bun test`,
# then either standalone executables (`bun.compile = { <bin> = "<entry.ts>"; }`) or the package
# tree under lib/node_modules/<name> with its package.json `bin` entries linked into bin/.
def knobs []: nothing -> record<root: string, deps: any, script: any, test: bool, flags: list<string>, compile: record> {
  knobs-for bun {root: ".", deps: null, script: null, test: true, flags: [], compile: {}}
}

const LINK_CACHE = path self bun-cache.ts

def project-dir []: nothing -> string { $"((ctx).src)/((knobs).root)" }

# bun reads packages from $BUN_INSTALL_CACHE_DIR/<name>@<version>@@@1; bun-cache.ts creates those
# entries as symlinks into the fetched tree (it runs under bun because the names involve bun's hash)
export def --env setup []: nothing -> nothing {
  let c = (ctx)
  let k = (knobs)
  let cache = $"($c.build)/bun-cache"
  load-env {
    BUN_INSTALL_CACHE_DIR: $cache, BUN_INSTALL: $"($c.build)/bun-home", XDG_CACHE_HOME: $"($c.build)/xdg"
    DO_NOT_TRACK: "1", CI: "true"
  }
  cd (project-dir)
  if $k.deps != null { x bun $LINK_CACHE $k.deps $cache }
  x bun install --frozen-lockfile --offline --ignore-scripts ...$k.flags
  fix-env-shebangs node_modules $c.njobs
  $env.PATH = ($env.PATH | prepend $"(project-dir)/node_modules/.bin")
}

# `bun run <bun.script>` if set
export def build []: nothing -> nothing {
  let script = (knobs).script
  if $script != null { cd (project-dir); x bun run $script }
}

# `bun test` unless bun.test = false
export def test []: nothing -> nothing {
  if (knobs).test { cd (project-dir); x bun test }
}

# compiled executables, or the package tree with its bin links
export def install []: nothing -> nothing {
  let c = (ctx)
  let k = (knobs)
  cd (project-dir)
  mkdir $"($c.out)/bin"
  if ($k.compile | is-not-empty) {
    for exe in ($k.compile | transpose name entry) {
      x bun build --compile --minify $exe.entry --outfile $"($c.out)/bin/($exe.name)"
    }
  } else {
    let tree = $"($c.out)/lib/node_modules/($c.spec.name)"
    mkdir ($tree | path dirname)
    ^cp -r . $tree
    for bin in (open package.json | get bin? | default {} | transpose name path) {
      ^ln -s $"($tree)/($bin.path)" $"($c.out)/bin/($bin.name)"
    }
  }
}
