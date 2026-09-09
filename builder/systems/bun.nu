use ../core.nu *
use ../node-common.nu

# A bun project: `bun install --offline` from fetch.bunDeps, optional `bun run <script>`, `bun test`,
# then either standalone executables (`bun.compile = { <bin> = "<entry.ts>"; }`) or the package
# tree under lib/node_modules/<name> with its package.json `bin` entries linked into bin/.
def knobs []: nothing -> record<deps: any, script: any, test: bool, flags: list<string>, compile: record> {
  knobs-for bun {deps: null, script: null, test: true, flags: [], compile: {}}
}

const LINK_CACHE = path self bun-cache.ts

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
  cd (project-dir bun)
  if $k.deps != null { x bun $LINK_CACHE $k.deps $cache }
  x bun install --frozen-lockfile --offline --ignore-scripts ...$k.flags
  node-common after-install $env.PWD
}

# `bun run <bun.script>` if set
export def build []: nothing -> nothing {
  let script = (knobs).script
  if $script != null { cd (project-dir bun); x bun run $script }
}

# `bun test` unless bun.test = false
export def test []: nothing -> nothing {
  if (knobs).test { cd (project-dir bun); x bun test }
}

# compiled executables, or the package tree with its bin links
export def install []: nothing -> nothing {
  let c = (ctx)
  let k = (knobs)
  cd (project-dir bun)
  if ($k.compile | is-empty) { node-common install-tree; return }
  mkdir $"($c.out)/bin"
  for exe in ($k.compile | transpose name entry) {
    x bun build --compile --minify $exe.entry --outfile $"($c.out)/bin/($exe.name)"
  }
}
