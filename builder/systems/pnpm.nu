use ../core.nu *
use ../node-common.nu

# pnpm install --offline against fetch.pnpmDeps as a file:// registry (`pnpm.deps`, pnpm checks each
# tarball against pnpm-lock.yaml's integrity), `pnpm run <script>`, `pnpm test`, and the pruned
# package as lib/node_modules/<name> with its bin links.

def options []: nothing -> record {
  options-for pnpm {script: "build", deps: null, flags: []}
}

# pnpm 10 reads npm_config_*, 11 only pnpm_config_*
def conf [settings: record]: nothing -> record {
  $settings | items {|k, v| [[$"npm_config_($k)" $v] [$"pnpm_config_($k)" $v]] } | flatten | into record
}

export def --env setup []: nothing -> nothing {
  let c = (ctx)
  let o = (options)
  load-env (conf {
    # pnpm 11 wants a host part (it names a cache dir) and opens tarballs at the URL minus
    # "file:", so "file:/" + store path: host "nix", file //nix/store/…
    registry: $"file:/($o.deps)/registry/", store_dir: $"($c.build)/pnpm-store", offline: "true"
    pm_on_fail: "ignore"  # run with our pnpm whatever version package.json's packageManager names
    minimum_release_age: "0"  # the release-age policy wants registry metadata we do not mirror
    side_effects_cache: "false", update_notifier: "false", loglevel: "warn"
  })
  $env.NODE_OPTIONS = "--no-deprecation"
  x pnpm install --offline --frozen-lockfile --ignore-scripts ...$o.flags
  node-common after-install $env.PWD
}

export def workdir []: nothing -> string { project-dir pnpm }

# pnpm run <pnpm.script> (null: nothing to build)
export def build []: nothing -> nothing {
  let script = (options).script
  if $script != null { x pnpm run $script }
}

# pnpm test
export def test []: nothing -> nothing { x pnpm test }

# pruned to production dependencies, as lib/node_modules/<name>
export def install []: nothing -> nothing {
  x pnpm prune --prod --ignore-scripts
  node-common install-tree
}
