use core.nu *

# pnpm install --offline from fetch.pnpmDeps, pnpm run <script>, pnpm test, install as lib/node_modules/<name> + bin links.
def knobs []: nothing -> record<root: string, script: string, deps: any, test: bool, flags: list<string>> { knobs-for pnpm {root: ".", script: "build", deps: null, test: true, flags: []} }

# offline node_modules: `pnpm.deps` is fetch.pnpmDeps output (registry tarballs by the lock's
# integrity). They seed a fresh content-addressed store, pnpm verifies each against pnpm-lock.yaml
export def --env setup []: nothing -> nothing {
  let c = (ctx); let k = (knobs)
  let dir = $"($c.src)/($k.root)"
  let store = $"($c.build)/pnpm-store"
  load-env {
    npm_config_store_dir: $store, npm_config_offline: "true", npm_config_update_notifier: "false", npm_config_loglevel: "warn"
    npm_config_manage_package_manager_versions: "false"  # do not fetch the pnpm version package.json names
    npm_config_side_effects_cache: "false", npm_config_verify_store_integrity: "false"
    CI: "true", NODE_OPTIONS: "--no-deprecation", XDG_DATA_HOME: $"($c.build)/xdg", XDG_CACHE_HOME: $"($c.build)/xdg"
  }
  cd $dir
  let tarballs = (open $"($k.deps)/index.json" | each {|t| $"($k.deps)/tarballs/($t.file)" })
  # `store add` takes tarball paths and unpacks them into the CAS the way a download would
  if ($tarballs | is-not-empty) { x pnpm store add ...$tarballs }
  x pnpm install --offline --frozen-lockfile --ignore-scripts ...$k.flags
  fix-env-shebangs node_modules $c.njobs
  $env.PATH = ($env.PATH | prepend $"($dir)/node_modules/.bin")
}

# pnpm run <script>
export def build []: nothing -> nothing { let k = (knobs); cd $"((ctx).src)/($k.root)"; x pnpm run $k.script ...$k.flags }
# pnpm test unless `pnpm.test = false`
export def test []: nothing -> nothing { cd $"((ctx).src)/((knobs).root)"; if (knobs).test { x pnpm test } }
# for packages whose product is the node package itself
export def install []: nothing -> nothing {
  let c = (ctx)
  cd $"($c.src)/((knobs).root)"
  x pnpm prune --prod --ignore-scripts
  let dst = $"($c.out)/lib/node_modules/($c.spec.name)"
  mkdir ($dst | path dirname) $"($c.out)/bin"
  ^cp -r . $dst
  for b in (open package.json | get bin? | default {} | transpose name path) { ^ln -s $"($dst)/($b.path)" $"($c.out)/bin/($b.name)" }
}
