use ../core.nu *
use ../node-common.nu

# A bun project: `bun install --offline` from fetch.bunDeps, optional `bun run <script>`, `bun test`,
# then either standalone executables (`bun.compile = { <bin> = "<entry.ts>"; }`) or the package
# tree under lib/node_modules/<name> with its package.json `bin` entries linked into bin/.
def options []: nothing -> record<deps: any, script: any, flags: list<string>, compile: record> {
  options-for bun {deps: null, script: null, flags: [], compile: {}}
}

const LINK_CACHE = path self bun-cache.ts

# bun reads packages from $BUN_INSTALL_CACHE_DIR/<name>@<version>@@@1; bun-cache.ts creates those
# entries as symlinks into the fetched tree (it runs under bun because the names involve bun's hash)
export def --env setup []: nothing -> nothing {
  let c = (ctx)
  let o = (options)
  let cache = $"($c.build)/bun-cache"
  load-env {BUN_INSTALL_CACHE_DIR: $cache, BUN_INSTALL: $"($c.build)/bun-home", DO_NOT_TRACK: "1"}
  cd (project-dir bun)
  x bun $LINK_CACHE $o.deps $cache
  x bun install --frozen-lockfile --offline --ignore-scripts ...$o.flags
  node-common after-install $env.PWD
}

# `bun run <bun.script>` if set
export def build []: nothing -> nothing {
  let script = (options).script
  if $script != null { x bun run $script }
}

# bun test
export def test []: nothing -> nothing { x bun test }

# compiled executables, or the package tree with its bin links
export def install []: nothing -> nothing {
  let c = (ctx)
  let o = (options)
  if ($o.compile | is-empty) { node-common install-tree; return }
  mkdir $"($c.out)/bin"
  for exe in ($o.compile | transpose name entry) {
    x bun build --compile --minify $exe.entry --outfile $"($c.out)/bin/($exe.name)"
  }
}
