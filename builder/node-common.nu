# What npm.nu, pnpm.nu and bun.nu share: the node_modules/.bin PATH entry after install and the
# "product is the package itself" install (lib/node_modules/<name> + package.json's bin links)
use core.nu *

# node_modules/.bin on PATH, its #!/usr/bin/env lines pointed at the seed
export def --env after-install [dir: string]: nothing -> nothing {
  fix-env-shebangs $"($dir)/node_modules" (ctx).njobs  # populated after the source tree was fixed
  $env.PATH = ($env.PATH | prepend $"($dir)/node_modules/.bin")
}

# the current directory as lib/node_modules/<name>, its package.json `bin` entries linked into bin/
export def install-tree []: nothing -> nothing {
  let c = (ctx)
  let tree = $"($c.out)/lib/node_modules/($c.spec.name)"
  mkdir ($tree | path dirname) $"($c.out)/bin"
  ^cp -r . $tree
  for bin in (open package.json | get bin? | default {} | transpose name path) {
    ^ln -s $"($tree)/($bin.path)" $"($c.out)/bin/($bin.name)"
  }
}
